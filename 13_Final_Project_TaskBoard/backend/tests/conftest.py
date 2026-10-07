# The test module builds its TestClient at import time. FastAPI only runs
# startup events when the client is used as a context manager, so the
# create_all in app.main never fires and the tasks table is missing. Creating
# the schema here fixes that without changing how the tests are written.
import os

os.environ.setdefault("DATABASE_URL", "sqlite:///./test.db")

import pytest

from app.db import Base, engine


@pytest.fixture(scope="session", autouse=True)
def schema():
    Base.metadata.create_all(bind=engine)
    yield
    Base.metadata.drop_all(bind=engine)
