"""Tiny OpenAPI 3.0 schema checker, enough for the PLK spec subset. Stdlib only."""
import json
import os
import re

_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_DT = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})?$")
_UUID = re.compile(r"^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$")
_DUR = re.compile(r"^-?(\d+\.)?\d{1,2}:\d{2}(:\d{2}(\.\d+)?)?$")
_FORMATS = {"date": _DATE, "date-time": _DT, "uuid": _UUID, "duration": _DUR}

# The spec declares no required fields, so list what the adapter cannot work without.
REQUIRED = {
    "ScheduleResponseDto": ["routes"],
    "RouteDto": ["scheduleId", "orderId", "operatingDates", "stations"],
    "StationOnRouteDto": ["stationId", "orderNumber"],
    "OperationResponseDto": ["trains", "pagination"],
    "TrainOperationDto": ["scheduleId", "orderId", "operatingDate", "trainStatus", "stations"],
    "OperationStationDto": ["stationId"],
    "DisruptionResponseDto": ["disruptions"],
    "DisruptionDto": ["disruptionId"],
    "DataVersionResponse": ["schedulesVersion"],
    "StationsResponse": ["stations", "totalPages"],
    "CarriersResponse": ["carriers"],
}


class SchemaError(Exception):
    pass


def load_spec(path=None):
    path = path or os.path.join(os.path.dirname(__file__), "..", "..", "spec", "openapi-subset.json")
    with open(path, encoding="utf8") as f:
        return json.load(f)["schemas"]


def _type_ok(t, v):
    if t == "string":
        return isinstance(v, str)
    if t == "integer":
        return isinstance(v, int) and not isinstance(v, bool)
    if t == "number":
        return isinstance(v, (int, float)) and not isinstance(v, bool)
    if t == "boolean":
        return isinstance(v, bool)
    if t == "array":
        return isinstance(v, list)
    if t == "object":
        return isinstance(v, dict)
    return True


def _check(schemas, sch, v, path, errs, name=None):
    if len(errs) >= 10:
        return
    if "$ref" in sch:
        name = sch["$ref"].rsplit("/", 1)[1]
        sch = schemas[name]
    if v is None:
        if not sch.get("nullable") and sch.get("type") is not None:
            errs.append("%s: null not allowed" % path)
        return
    t = sch.get("type")
    if t and not _type_ok(t, v):
        errs.append("%s: expected %s, got %s" % (path, t, type(v).__name__))
        return
    f = sch.get("format")
    if f in _FORMATS and isinstance(v, str) and not _FORMATS[f].match(v):
        errs.append("%s: bad %s value" % (path, f))
    if "enum" in sch and v not in sch["enum"]:
        errs.append("%s: not in enum" % path)
    if isinstance(v, dict):
        for k in REQUIRED.get(name, []):
            if v.get(k) is None:
                errs.append("%s.%s: required by adapter" % (path, k))
        props = sch.get("properties", {})
        for k, sub in props.items():
            if k in v:
                _check(schemas, sub, v[k], "%s.%s" % (path, k), errs)
        ap = sch.get("additionalProperties")
        if isinstance(ap, dict):
            for k, val in v.items():
                if k not in props:
                    _check(schemas, ap, val, "%s[%s]" % (path, k), errs)
    elif isinstance(v, list) and "items" in sch:
        for i, item in enumerate(v):
            _check(schemas, sch["items"], item, "%s[%d]" % (path, i), errs)


def validate(schemas, name, data):
    """Raise SchemaError listing the first problems. Extra fields are tolerated (minor API additions)."""
    errs = []
    _check(schemas, {"$ref": "#/components/schemas/" + name}, data, name, errs)
    if errs:
        raise SchemaError("; ".join(errs))
