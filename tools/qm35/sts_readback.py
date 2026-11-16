"""Hardware-free validation of GET evidence and exact FFF3 service data bytes."""
STS_LENGTHS = {"VendorId": 2, "StaticStsIv": 6}


def verify(report, service_data=None):
    if report.get("ok") is not True or report.get("status", {}).get("name") != "Ok":
        raise ValueError("GET unverified: " + report.get("error", "missing/failed status"))
    fields = report.get("fields", [])
    result = {}
    for name, length in STS_LENGTHS.items():
        matches = [field for field in fields if field.get("name") == name]
        if len(matches) != 1:
            raise ValueError(name + ": missing/duplicate GET field")
        field = matches[0]
        try:
            requested = bytes.fromhex(field["requested_raw_hex"])
            returned = bytes.fromhex(field["returned_raw_hex"])
        except (KeyError, TypeError, ValueError) as exc:
            raise ValueError(name + ": missing/invalid GET bytes") from exc
        if len(returned) != length or returned != requested or field.get("difference") is not None:
            raise ValueError(name + ": GET mismatch")
        result[name] = returned
    if service_data is not None:
        # Exact layout built and emitted by advertise_dltdoa_oob.build (UUID included).
        if len(service_data) != 29 or service_data[:9] != bytes.fromhex("f3 ff f0 5f 09 02 00 06 02") or service_data[11:13] != bytes.fromhex("27 02") or service_data[15:17] != bytes.fromhex("28 06") or service_data[23:25] != bytes.fromhex("9f 04"):
            raise ValueError("OOB: unexpected service-data layout")
        if service_data[13:15] != result["VendorId"] or service_data[17:23] != result["StaticStsIv"]:
            raise ValueError("OOB STS bytes differ from A GET")
    return result
