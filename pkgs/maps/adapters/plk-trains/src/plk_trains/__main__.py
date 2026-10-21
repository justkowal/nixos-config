import logging
import os
import sys
import tomllib

from .app import App


def main():
    logging.basicConfig(stream=sys.stdout, level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s %(message)s")
    path = os.environ.get("PLK_CONFIG", "/app/config.toml")
    with open(path, "rb") as f:
        cfg = tomllib.load(f)
    App(cfg).run(int(os.environ.get("PORT", "8080")))


main()
