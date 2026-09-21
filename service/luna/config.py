from dataclasses import dataclass
import os
from urllib.parse import urlparse


@dataclass(frozen=True)
class Settings:
    token: str
    hermes_url: str = "http://127.0.0.1:8642"
    hermes_key: str = ""
    openai_key: str = ""
    voice_model: str = "gpt-live-1"
    router_model: str = "gpt-5.6-luna"
    database: str = ".state/luna.sqlite"
    demo: bool = False

    @classmethod
    def from_environment(cls):
        demo = os.getenv("LUNA_DEMO", "").lower() in {"true", "1"}
        token = os.getenv("LUNA_TOKEN", "") or ("luna-local-demo" if demo else "")
        if len(token) < 12:
            raise ValueError("Set LUNA_TOKEN to a long random token, or start with --demo.")
        url = os.getenv("HERMES_BASE_URL", "http://127.0.0.1:8642").rstrip("/")
        parsed = urlparse(url)
        if parsed.scheme not in {"http", "https"} or not parsed.hostname or parsed.username:
            raise ValueError("HERMES_BASE_URL must be an HTTP(S) URL without embedded credentials.")
        return cls(token=token, hermes_url=url, hermes_key=os.getenv("HERMES_API_KEY", ""),
                   openai_key=os.getenv("OPENAI_API_KEY", ""),
                   voice_model=os.getenv("LUNA_VOICE_MODEL", "gpt-live-1"),
                   router_model=os.getenv("LUNA_ROUTER_MODEL", "gpt-5.6-luna"),
                   database=os.getenv("LUNA_DATABASE", ".state/demo.sqlite" if demo else ".state/luna.sqlite"),
                   demo=demo)
