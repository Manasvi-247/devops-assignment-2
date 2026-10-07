import os
os.environ["DATABASE_URL"] = "sqlite:///./test.db"

from fastapi.testclient import TestClient
from app.main import app

client = TestClient(app)

def test_health():
    assert client.get("/health").json() == {"status": "UP"}

def test_root():
    response = client.get("/")
    assert response.status_code == 200
    assert response.json()["service"] == "TaskBoard API"

def test_create_task_validation():
    response = client.post("/api/tasks", json={"title": "Deploy application", "priority": "HIGH", "assignee": "Student"})
    assert response.status_code == 201
    assert response.json()["title"] == "Deploy application"

def test_ready():
    assert client.get("/ready").json() == {"status": "READY"}

def test_list_tasks_returns_a_list():
    response = client.get("/api/tasks")
    assert response.status_code == 200
    assert isinstance(response.json(), list)

def test_get_task_not_found():
    assert client.get("/api/tasks/99999").status_code == 404

def test_update_task():
    created = client.post("/api/tasks", json={"title": "Update me", "priority": "LOW"}).json()
    response = client.put(f"/api/tasks/{created['id']}", json={"status": "DONE"})
    assert response.status_code == 200
    assert response.json()["status"] == "DONE"

def test_delete_task():
    created = client.post("/api/tasks", json={"title": "Delete me", "priority": "LOW"}).json()
    assert client.delete(f"/api/tasks/{created['id']}").status_code == 204
    assert client.get(f"/api/tasks/{created['id']}").status_code == 404

def test_stats_shape():
    body = client.get("/api/tasks/stats").json()
    assert set(body) == {"total", "todo", "inProgress", "done"}

def test_create_requires_a_title():
    assert client.post("/api/tasks", json={"priority": "HIGH"}).status_code == 422
