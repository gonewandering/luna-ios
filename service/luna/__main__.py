import argparse
import os
from dotenv import load_dotenv
import uvicorn
from .config import Settings
from .app import create_app


def main():
    parser = argparse.ArgumentParser(description="Luna voice bridge for Hermes")
    parser.add_argument("--demo", action="store_true", help="Use sample sessions; no real Hermes tasks are executed")
    args = parser.parse_args()
    load_dotenv()
    if args.demo: os.environ["LUNA_DEMO"] = "true"
    settings = Settings.from_environment()
    host = os.getenv("LUNA_HOST", "127.0.0.1")
    if settings.demo and settings.token == "luna-local-demo" and host not in {"127.0.0.1", "localhost", "::1"}:
        raise SystemExit("Set a private LUNA_TOKEN before exposing demo mode beyond loopback.")
    uvicorn.run(create_app(settings), host=host, port=int(os.getenv("LUNA_PORT", "8787")))


if __name__ == "__main__": main()
