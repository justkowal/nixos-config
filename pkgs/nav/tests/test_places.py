import datetime
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import places as p  # noqa: E402


class FakeConn:
    def __init__(self, rows):
        self.rows, self.sql = rows, []

    def run(self, sql, **kw):
        self.sql.append((sql, kw))
        return self.rows.pop(0) if self.rows else []

    def close(self):
        pass


def monday(hh):
    return datetime.datetime(2026, 10, 19, hh, 0, tzinfo=p.TZ)


class Explore(unittest.TestCase):
    def setUp(self):
        p._now = lambda: monday(10)

    def test_nearest_first_with_open_state_and_radius_filter(self):
        rows = [[("N", 1, "amenity", "cafe", "Far", 19.9380, 50.0614, "Mo-Su 08:00-22:00"),
                 ("N", 2, "amenity", "cafe", "Near", 19.9372, 50.0615, "Mo-Su 12:00-22:00"),
                 ("N", 3, "amenity", "cafe", "TooFar", 19.99, 50.0614, None)], []]
        p._db = lambda: FakeConn(rows)
        out = p.explore("cafe", 50.0614, 19.9371, 800)
        self.assertEqual([c["title"] for c in out["places"]], ["Near", "Far"])
        self.assertEqual([c["open"] for c in out["places"]], [False, True])
        self.assertEqual(out["places"][0]["cat"], "Cafe")

    def test_unknown_category_and_bad_radius(self):
        with self.assertRaises(ValueError):
            p.explore("nope", 50, 19)
        p._db = lambda: FakeConn([[], []])
        p.explore("cafe", 50, 19, 999999)  # clamped, not an error

    def test_all_categories_nearby(self):
        rows = [
            ("N", 1, "amenity", "restaurant", "Resto", 19.9380, 50.0614, None),
            ("N", 2, "tourism", "museum", "Museum", 19.9372, 50.0615, None),
            ("N", 1, "amenity", "restaurant", "Resto Dup", 19.9380, 50.0614, None),  # duplicate id
            ("N", 3, "shop", "bakery", "Bakery", 19.99, 50.0614, None),  # outside radius
        ]
        conn = FakeConn([rows])
        p._db = lambda: conn
        out = p.explore("all", 50.0614, 19.9371, 800)
        self.assertEqual(out["category"], "Nearby")
        self.assertEqual([c["title"] for c in out["places"]], ["Museum", "Resto"])
        self.assertEqual([c["cat"] for c in out["places"]], ["Museum", "Restaurant"])
        self.assertIn("class = ANY(:cls)", conn.sql[0][0])
        self.assertEqual(conn.sql[0][1]["cls"], ["amenity", "shop", "tourism", "leisure", "historic"])

        # Also works with cat=None and cat=""
        conn2 = FakeConn([[("N", 2, "tourism", "museum", "Museum", 19.9372, 50.0615, None)]])
        p._db = lambda: conn2
        out_none = p.explore(None, 50.0614, 19.9371, 800)
        self.assertEqual(out_none["category"], "Nearby")
        self.assertEqual(len(out_none["places"]), 1)



class Card(unittest.TestCase):
    def test_card_from_tags(self):
        tags = {"phone": "+48 12 345 67 89", "website": "wierzynek.pl", "wheelchair": "yes", "cuisine": "polish;regional", "outdoor_seating": "yes",
                "diet:vegan": "yes", "wikipedia": "pl:Wierzynek", "wikidata": "Q9373377", "opening_hours": "Mo-Su 12:00-23:00"}
        addr = {"addr:street": "Rynek Główny", "addr:housenumber": "15", "addr:postcode": "31-008", "addr:city": "Kraków"}
        row = ("N", 475613615, "amenity", "restaurant", "Wierzynek", 19.9366, 50.0617, "Mo-Su 12:00-23:00", json.dumps(tags), json.dumps(addr), None, None)
        p._db = lambda: FakeConn([[row]])
        p._now = lambda: monday(10)
        c = p.place_card(osm="N475613615")
        self.assertEqual(c["address"], "Rynek Główny 15, 31-008 Kraków")
        self.assertEqual(c["website"], "https://wierzynek.pl")
        self.assertEqual(c["hours"]["text"], "Closed, opens 12:00")
        self.assertIn("Wheelchair accessible", c["attributes"])
        self.assertIn("Cuisine: polish, regional", c["attributes"])
        self.assertIn("Vegan options", c["attributes"])
        self.assertEqual(c["osm_url"], "https://www.openstreetmap.org/node/475613615")

    def test_bad_ids_are_rejected_before_any_query(self):
        p._db = lambda: (_ for _ in ()).throw(AssertionError("no query expected"))
        with self.assertRaises(ValueError):
            p.place_card(osm="N1; DROP TABLE placex")

    def test_unsafe_website_schemes_are_dropped(self):
        self.assertIsNone(p._safe_url("javascript:alert(1)"))
        self.assertEqual(p._safe_url("https://a.pl/x"), "https://a.pl/x")


class More(unittest.TestCase):
    def setUp(self):
        p._cache.clear()
        self.urls = []

        def get(url, timeout=6):
            self.urls.append(url)
            if "wikipedia.org" in url:
                return {"extract": "Historic restaurant.", "description": "restaurant", "content_urls": {"desktop": {"page": "https://pl.wikipedia.org/wiki/W"}}, "thumbnail": {"source": "https://upload.wikimedia.org/x.jpg"}}
            if "wikidata.org" in url:
                return {"entities": {"Q1": {"descriptions": {"pl": {"value": "opis"}}, "sitelinks": {"plwiki": {"title": "Tytuł"}}, "claims": {"P18": [{"mainsnak": {"datavalue": {"value": "Foto Test.jpg"}}}]}}}}
            return {"reviews": [{"payload": {"rating": 80, "opinion": "Nice", "iat": 1700000000}}]}
        p._get_json = get

    def test_wikipedia_description_photo_and_open_review(self):
        out = p.more({"wikipedia": "pl:Wierzynek", "wikidata": None, "lat": 50.06, "lon": 19.93, "title": "Wierzynek"})
        self.assertEqual(out["description"]["source"], "Wikipedia (pl)")
        self.assertEqual(out["description"]["license"], "CC BY-SA")
        self.assertTrue(out["photo"].startswith("https://upload.wikimedia.org"))
        self.assertEqual(out["reviews"]["count"], 1)
        self.assertEqual(out["reviews"]["average"], 4.0)

    def test_wikidata_resolves_the_article_when_osm_has_none(self):
        out = p.more({"wikipedia": None, "wikidata": "Q1", "lat": 50.06, "lon": 19.93, "title": "X"})
        self.assertTrue(any("pl.wikipedia.org" in u and "Tytu%C5%82" in u for u in self.urls))
        self.assertEqual(out["description"]["source"], "Wikipedia (pl)")

    def test_failing_sources_leave_fields_empty_not_errors(self):
        def boom(url, timeout=6):
            raise OSError("down")
        p._get_json = boom
        out = p.more({"wikipedia": "pl:X", "wikidata": "Q5", "osm_description": "A cafe.", "lat": 1, "lon": 1, "title": "X"})
        self.assertEqual(out["description"]["source"], "OpenStreetMap")
        self.assertIsNone(out["photo"])
        self.assertEqual(out["reviews"]["count"], 0)

    def test_language_and_ids_are_validated(self):
        self.assertIsNone(p.wiki_summary("evil.com/x:Title"))
        self.assertIsNone(p.wikidata("Q1; drop"))


class Images(unittest.TestCase):
    def test_only_wikimedia_hosts_are_fetched(self):
        for bad in ("http://upload.wikimedia.org/a.jpg", "https://evil.example/a.jpg", "https://upload.wikimedia.org:8443/a.jpg", "https://user@upload.wikimedia.org/a.jpg"):
            with self.assertRaises(ValueError):
                p.fetch_image(bad)


if __name__ == "__main__":
    unittest.main()
