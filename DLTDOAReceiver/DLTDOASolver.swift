import Foundation
import simd

struct AnchorObservation: Identifiable {
    var id: Int { address }
    let address: Int
    let clusterInitiatorAddress: Int?
    let position2D: SIMD2<Double>
    let position3D: SIMD3<Double>
    let isRelative: Bool
    let receiveTime: Double
    let transmitTime: Double
    let signalStrength: Double
    let measurementTypeDescription: String
    let updatedAt: Date

    var elapsedTime: Double {
        receiveTime - transmitTime
    }
}

struct SolvedPosition {
    let x: Double
    let y: Double
    let residualMeters: Double
    let anchorCount: Int
    let referenceAnchorAddress: Int
    let timestamp: Date
}

enum DLTDOASolver {
    private static let speedOfLight: Double = 299_792_458.0

    /// Solves 2D receiver position (x, y) from >= 3 anchor observations using Gauss-Newton TDoA.
    /// Note: Assumes all anchors share a consistent coordinate frame (relative meters or geodetic).
    static func solve2D(
        observations: [AnchorObservation],
        knownReceiverZ: Double = 0.0,
        maxIterations: Int = 25
    ) -> SolvedPosition? {
        // Filter recent observations (e.g. within 2 seconds) with valid finite coordinates
        let now = Date()
        let active = observations.filter {
            now.timeIntervalSince($0.updatedAt) <= 2.0 &&
            $0.position3D.x.isFinite &&
            $0.position3D.y.isFinite &&
            $0.receiveTime.isFinite &&
            $0.transmitTime.isFinite
        }

        guard active.count >= 3 else { return nil }

        // Choose reference anchor: prefer strongest signal or lowest address for stability
        guard let ref = active.max(by: { $0.signalStrength < $1.signalStrength }) else {
            return nil
        }

        // Convert to local 2D meters if geodetic (equirectangular around reference anchor)
        let points3D: [Int: SIMD3<Double>] = Dictionary(
            uniqueKeysWithValues: active.map { obs in
                if obs.isRelative {
                    return (obs.address, obs.position3D)
                } else {
                    let lat0 = ref.position3D.x * .pi / 180.0
                    let lon0 = ref.position3D.y * .pi / 180.0
                    let lat = obs.position3D.x * .pi / 180.0
                    let lon = obs.position3D.y * .pi / 180.0
                    let earthRadius = 6_378_137.0
                    let x = (lon - lon0) * cos(lat0) * earthRadius
                    let y = (lat - lat0) * earthRadius
                    let z = obs.position3D.z
                    return (obs.address, SIMD3<Double>(x, y, z))
                }
            }
        )

        guard let refPos = points3D[ref.address] else { return nil }

        let others = active.filter { $0.address != ref.address }
        guard others.count >= 2 else { return nil }

        // Initial guess: centroid of anchor XY coordinates
        var est = SIMD2<Double>(0, 0)
        for obs in active {
            if let p = points3D[obs.address] {
                est += SIMD2<Double>(p.x, p.y)
            }
        }
        est /= Double(active.count)

        let refElapsed = ref.elapsedTime

        for _ in 0..<maxIterations {
            let dRef = hypot(
                hypot(est.x - refPos.x, est.y - refPos.y),
                knownReceiverZ - refPos.z
            )
            guard dRef > 1e-6 else { break }

            // Normal equations J^T J delta = -J^T r (2x2 system)
            var h00 = 0.0, h01 = 0.0, h11 = 0.0
            var g0 = 0.0, g1 = 0.0

            for obs in others {
                guard let pos = points3D[obs.address] else { continue }
                let dI = hypot(
                    hypot(est.x - pos.x, est.y - pos.y),
                    knownReceiverZ - pos.z
                )
                guard dI > 1e-6 else { continue }

                // Measured range difference (d_i - d_ref)
                let measuredDiff = (obs.elapsedTime - refElapsed) * speedOfLight
                let predictedDiff = dI - dRef
                let residual = predictedDiff - measuredDiff

                let jx = (est.x - pos.x) / dI - (est.x - refPos.x) / dRef
                let jy = (est.y - pos.y) / dI - (est.y - refPos.y) / dRef

                h00 += jx * jx
                h01 += jx * jy
                h11 += jy * jy

                g0 += jx * residual
                g1 += jy * residual
            }

            // Damped Levenberg-Marquardt regularization
            let lambda = 1e-4
            let a00 = h00 + lambda
            let a11 = h11 + lambda
            let det = a00 * a11 - h01 * h01
            guard abs(det) > 1e-12 else { break }

            let dx = (-a11 * g0 + h01 * g1) / det
            let dy = (h01 * g0 - a00 * g1) / det

            est.x += dx
            est.y += dy

            if hypot(dx, dy) < 1e-4 {
                break
            }
        }

        // Compute RMS residual
        let dRefFinal = hypot(
            hypot(est.x - refPos.x, est.y - refPos.y),
            knownReceiverZ - refPos.z
        )
        var sqErr = 0.0
        for obs in others {
            guard let pos = points3D[obs.address] else { continue }
            let dI = hypot(
                hypot(est.x - pos.x, est.y - pos.y),
                knownReceiverZ - pos.z
            )
            let measuredDiff = (obs.elapsedTime - refElapsed) * speedOfLight
            let err = (dI - dRefFinal) - measuredDiff
            sqErr += err * err
        }
        let rms = sqrt(sqErr / Double(others.count))

        return SolvedPosition(
            x: est.x,
            y: est.y,
            residualMeters: rms,
            anchorCount: active.count,
            referenceAnchorAddress: ref.address,
            timestamp: now
        )
    }
}
