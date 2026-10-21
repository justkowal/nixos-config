"""Writes the synthetic-from-spec fixtures. Nothing here was recorded from the live API.

Station IDs, order IDs and times are invented; only the shapes follow the OpenAPI spec v1.1.4.
Coordinates in nominatim.json are rough approximations for test purposes.
"""
import json
import os
from datetime import date, timedelta

OUT = os.path.join(os.path.dirname(__file__), "fixtures")
NOTE = "synthetic-from-spec: invented values, shapes from PLK OpenAPI v1.1.4, not recorded"
KRK, MIE, ZAW, CZE = 900001, 900002, 900003, 900004
NAMES = {KRK: "Kraków Główny", MIE: "Miechów", ZAW: "Zawiercie", CZE: "Częstochowa"}
DATES = [(date(2026, 10, 20) + timedelta(days=i)).isoformat() for i in range(32)]


def st(sid, n, arr=None, dep=None, aday=0, dday=0, stype=(1, "Postój handlowy")):
    return {"stationId": sid, "orderNumber": n,
            "arrivalTime": arr, "arrivalDay": aday if arr else None,
            "departureTime": dep, "departureDay": dday if dep else None,
            "stopTypeId": stype[0], "stopTypeName": stype[1]}


def route(oid, name, carrier, cat, num, stations, toid=None, dates=DATES, sid=26):
    r = {"scheduleId": sid, "orderId": oid, "name": name, "carrierCode": carrier,
         "nationalNumber": num, "commercialCategorySymbol": cat, "operatingDates": dates,
         "stations": stations, "connections": []}
    if toid is not None:
        r["trainOrderId"] = toid
    return r


def dicts(ids):
    return {"stations": {str(i): {"id": i, "name": NAMES[i]} for i in ids},
            "services": {}, "connectionTypes": {}, "commercialCategories": {}, "stopTypes": {},
            "carriers": {"IC": "PKP Intercity S.A.", "KS": "Koleje Slaskie sp. z o.o."}}


def sched(routes):
    return {"_fixture": NOTE, "generatedAt": "2026-10-21T00:30:00Z",
            "period": {"from": "2026-10-21T00:00:00", "to": "2026-11-20T00:00:00"},
            "routes": routes, "dictionaries": dicts(NAMES)}


down = sched([
    route(111111, "REYMONT", "IC", "IC", "5310", [
        st(KRK, 1, dep="08:00:00"),
        st(MIE, 2, "08:35:00", "08:36:00"),
        st(ZAW, 3, "09:15:00", "09:16:00"),
        st(CZE, 4, "09:50:00")]),
    route(222222, None, "KS", "R", "90123", [
        st(KRK, 1, dep="22:40:00"),
        st(MIE, 2, "23:20:00", "23:21:00"),
        st(ZAW, 3, "00:10:00", "00:11:00", aday=1, dday=1),
        st(CZE, 4, "00:45:00", aday=1)]),
    route(333333, None, "KS", "R", "90125", [
        st(KRK, 1, dep="12:00:00"),
        st(MIE, 2, "12:30:00", "12:31:00", stype=(9, "Przejazd bez zatrzymania")),
        st(CZE, 3, "13:40:00")], toid=333334),
])
up = sched([
    route(111112, "REYMONT", "IC", "IC", "5311", [
        st(CZE, 1, dep="17:00:00"),
        st(ZAW, 2, "17:35:00", "17:36:00"),
        st(KRK, 3, "18:40:00")]),
])


def ops_st(sid, seq, ad=None, dd=None, cancelled=False):
    return {"stationId": sid, "plannedSequenceNumber": seq, "actualSequenceNumber": seq,
            "arrivalDelayMinutes": ad, "departureDelayMinutes": dd, "isConfirmed": ad is not None,
            "isCancelled": cancelled}


def train(oid, status, stations, toid=None, day="2026-10-21", sid=26):
    return {"scheduleId": sid, "orderId": oid, "trainOrderId": toid if toid is not None else oid,
            "operatingDate": day, "trainStatus": status, "stations": stations}


ops = {"_fixture": NOTE, "generatedAt": "2026-10-21T08:20:05Z",
       "pagination": {"page": 1, "pageSize": 2000, "totalCount": 6, "totalPages": 1,
                      "hasNextPage": False, "hasPreviousPage": False},
       "trains": [
           train(111111, "P", [ops_st(KRK, 1, None, 4), ops_st(MIE, 2, 5, 6), ops_st(ZAW, 3),
                               ops_st(CZE, 4)]),
           train(222222, "X", [ops_st(KRK, 1, None, None, True)], day="2026-10-20"),
           train(333333, "Q", [ops_st(KRK, 1, None, 0), ops_st(MIE, 2, None, None, True),
                               ops_st(CZE, 3)], toid=333334),
           train(111112, "C", [ops_st(CZE, 1, None, 0)], day="2026-10-20"),
           train(555555, "P", [ops_st(KRK, 1, None, 3)]),
           train(111111, "S", [ops_st(KRK, 1)], day="2026-12-31"),
       ]}

disr = {"_fixture": NOTE, "generatedAt": "2026-10-21T08:00:00Z",
        "disruptionTypes": {"utr_32": "Utrudnienie: prace torowe"},
        "stations": {str(KRK): NAMES[KRK]},
        "disruptions": [
            {"disruptionId": 1, "disruptionTypeCode": "utr_32", "startStationId": KRK,
             "endStationId": MIE, "message": "Prace torowe, mozliwe opoznienia.",
             "affectedRoutes": [{"scheduleId": 26, "orderId": 111111, "operatingDate": "2026-10-21",
                                 "stationId": KRK, "sequenceNumber": 1}]},
            {"disruptionId": 2, "disruptionTypeCode": "utr_32", "message": "Inna trasa.",
             "affectedRoutes": [{"scheduleId": 26, "orderId": 999, "operatingDate": "2026-10-21",
                                 "stationId": KRK, "sequenceNumber": 1}]}]}

dv = {"dataVersion": "11111111-1111-1111-1111-111111111111",
      "schedulesVersion": "22222222-2222-2222-2222-222222222222",
      "operationsVersion": "33333333-3333-3333-3333-333333333333", "timestamp": "2026-10-21T08:20:00Z"}
stations = {"generatedAt": "2026-10-21T00:00:00Z", "totalCount": 4, "returnedCount": 4, "page": 1,
            "pageSize": 5000, "totalPages": 1, "stations": [{"id": i, "name": n} for i, n in NAMES.items()]}
carriers = {"generatedAt": "2026-10-21T00:00:00Z",
            "carriers": [{"code": "IC", "name": "PKP Intercity S.A.", "validFrom": None, "validTo": None},
                         {"code": "KS", "name": "Koleje Slaskie sp. z o.o.", "validFrom": None,
                          "validTo": None}]}
nominatim = {
    "Kraków Główny": [{"category": "building", "type": "yes", "lat": "50.0", "lon": "19.0"},
                      {"category": "railway", "type": "station", "lat": "50.0679", "lon": "19.9477"}],
    "Miechów": [{"category": "railway", "type": "station", "lat": "50.3578", "lon": "20.0289"}],
    "Zawiercie": [{"category": "railway", "type": "station", "lat": "50.4903", "lon": "19.4126"}],
    "Częstochowa": [{"category": "railway", "type": "station", "lat": "50.8118", "lon": "19.1203"}],
}

for name, obj in (("schedules_down", down), ("schedules_up", up), ("operations", ops),
                  ("disruptions", disr), ("data_version", dv), ("stations", stations),
                  ("carriers", carriers), ("nominatim", nominatim)):
    with open(os.path.join(OUT, name + ".json"), "w", encoding="utf8") as f:
        json.dump(obj, f, indent=1, ensure_ascii=False)
        f.write("\n")
