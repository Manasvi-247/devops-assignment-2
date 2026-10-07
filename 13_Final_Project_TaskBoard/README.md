# Final Project: TaskBoard

**Name:** Manasvi Sabbarwal
**Roll No:** 24BCS10406

A three service application built and run with Docker Compose: a FastAPI
backend, a React single page app served by nginx, and PostgreSQL. Every REST
endpoint is exercised, the schema is created by a migration, the tests run
inside the shipped image, and the data survives a restart.

Every output block below is quoted from [`output.log`](output.log), written by
[`verify.sh`](verify.sh). The exceptions are section 10, which quotes the
failed runs that led to the current one and so cannot come from a clean log,
and the image size table in section 2, which is `docker images` rather than
anything the script captures. Both are marked where they appear.

---

## 1. The application

| Service | Image | Container port | Job |
|---|---|---|---|
| `postgres` | `postgres:16-alpine` | 5432 | the only stateful piece, backed by a named volume |
| `backend` | built from `backend/` | 8000 | FastAPI, SQLAlchemy, Alembic, Prometheus metrics |
| `frontend` | built from `frontend/` | 80 | nginx serving the built SPA and proxying `/api` |

The board is one table. A task has a title, description, priority
(`LOW`/`MEDIUM`/`HIGH`), status (`TODO`/`IN_PROGRESS`/`DONE`), an assignee and
a creation timestamp. Pydantic enforces those as `Literal` types, so an invalid
priority never reaches the database.

### How the three fit together

The browser only ever talks to the frontend container on port 80. It never
addresses the backend directly. `frontend/nginx.conf` does the joining:

```nginx
location / {
  try_files $uri /index.html;
}

location /api/ {
  proxy_pass http://backend:8000;
}
```

`try_files $uri /index.html` is what makes client side routing work: any path
that is not a real file falls back to the SPA shell. The `/api/` block hands
everything else to the backend by its **compose service name**, which the
embedded DNS server resolves on the shared network. The React code therefore
calls a bare `const API = '/api'` with no host and no port, which means there
is no CORS preflight and no build time knowledge of where the backend lives.

The backend reaches PostgreSQL the same way, by service name:

```
DATABASE_URL: postgresql+psycopg://taskboard:taskboard@postgres:5432/taskboard
```

Only the published host ports differ between machines. The wiring inside the
network does not change at all.

### Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/` | service name and version |
| GET | `/health` | liveness, no dependencies touched |
| GET | `/ready` | readiness, runs a real query against PostgreSQL |
| GET | `/api/tasks` | list, newest first |
| GET | `/api/tasks/stats` | counts grouped by status |
| GET | `/api/tasks/{id}` | one task, 404 if absent |
| POST | `/api/tasks` | create, 201 |
| PUT | `/api/tasks/{id}` | partial update |
| DELETE | `/api/tasks/{id}` | delete, 204 with no body |
| GET | `/metrics` | Prometheus exposition |

`/health` and `/ready` are deliberately different. Health answers "is the
process alive", and touches nothing, so a database outage must not restart the
API. Ready answers "can this instance serve traffic", and runs a count against
the `tasks` table, so a database outage does take it out of rotation. Wiring
both to the same check is the usual mistake, and it turns a database blip into
a restart loop.

Route order in `main.py` matters too. `/api/tasks/stats` is declared **before**
`/api/tasks/{task_id}`, because FastAPI matches in declaration order and
`stats` would otherwise be captured as a `task_id` and fail to parse as an int.

---

## 2. The Dockerfiles

### Backend: single stage, and why that is fine

```dockerfile
FROM python:3.12-slim
WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt && useradd --create-home --uid 10001 appuser
COPY alembic.ini ./
COPY alembic ./alembic
COPY app ./app
COPY pytest.ini ./
COPY tests ./tests
USER 10001
EXPOSE 8000
CMD ["sh", "-c", "alembic upgrade head && uvicorn app.main:app --host 0.0.0.0 --port 8000"]
```

Python is interpreted, so there is no build output to separate from a
toolchain. A second stage would buy nothing. The things that do earn their
place:

- `requirements.txt` is copied and installed **before** the application code.
  Editing `main.py` then reuses the cached dependency layer instead of
  reinstalling SQLAlchemy and psycopg.
- `PYTHONUNBUFFERED=1` means uvicorn and Alembic logs appear in
  `docker compose logs` immediately rather than sitting in a pipe buffer. That
  is what made the failure in section 10 visible at all.
- `USER 10001` drops root. The container owns nothing it does not need to
  write, which showed up honestly in the pytest run (see section 8).
- The `CMD` chains `alembic upgrade head && uvicorn`. The `&&` is the point: if
  the migration fails the server never starts, so the API cannot serve traffic
  against a schema it does not expect.
- The tests are copied in so the suite can be run against the real shipped
  artefact, not a local checkout that happens to look similar.

### Frontend: multi stage, and why it has to be

```dockerfile
FROM node:22-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm install
COPY . .
RUN npm run build

FROM nginx:1.27-alpine
COPY --from=build /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
```

Vite turns JSX into static `.js` and `.css` files. Nothing that produced them
is needed afterwards: not Node, not npm, not `node_modules`, not the JSX
source. Only `/app/dist` crosses the `COPY --from=build` line, and the final
image starts from `nginx:1.27-alpine` with no Node in it at all.

The sizes say it plainly. These three rows are pulled out of
`docker images --format '{{.Repository}}:{{.Tag}} {{.Size}}'`, with the role of
each added on the right:

```text
node:22-alpine                              234MB   build stage base
nginx:1.27-alpine                          76.8MB   runtime base
13_final_project_taskboard-frontend:latest 76.3MB   final image
```

The finished image is about the size of bare nginx, because the built bundle is
a few hundred kilobytes of static files. Everything heavy was left behind in a
stage that is never shipped. That is smaller, faster to pull, and a much
smaller attack surface, since a package manager and a JavaScript runtime are
exactly the tools you do not want sitting in a production container.

`docker compose images` reports different numbers, because it reports the
compressed sizes from the manifest rather than the on disk size:

```text
$ docker compose images
CONTAINER                               REPOSITORY                            TAG                 PLATFORM            IMAGE ID            SIZE                CREATED
13_final_project_taskboard-backend-1    13_final_project_taskboard-backend    latest              linux/arm64         f90bb5686346        70.8MB              11 seconds ago
13_final_project_taskboard-frontend-1   13_final_project_taskboard-frontend   latest              linux/arm64         0e46acfd02ef        21.9MB              11 seconds ago
13_final_project_taskboard-postgres-1   postgres                              16-alpine           linux/arm64/v8      721873c34ceb        114MB               12 seconds ago
```

Both measurements are real, they just answer different questions: 21.9MB is
what travels over the network, 76.3MB is what lands on the disk.

---

## 3. The compose stack, and the override

[`docker-compose.yml`](docker-compose.yml) is the course file, unchanged.
Three services, one named volume, host ports 8000, 3000 and 5432.

On this machine all three of those host ports are already taken by the editor
and its language servers, so the stack could not bind them. The fix lives in
[`docker-compose.override.yml`](docker-compose.override.yml), which compose
loads automatically and merges on top:

```yaml
services:
  backend:
    ports: !override
      - "127.0.0.1:18000:8000"
```

Two details in that one line are worth stating honestly.

**`!override` is mandatory here.** Compose merges `ports` as a sequence, and
the default for sequences is to **append**, not replace. Without the tag the
merged service ends up with both `8000:8000` and `18000:8000`, and the stack
fails on the port it was trying to avoid. `!override` tells compose to discard
the base list.

**Only the host side moves.** The container still listens on 8000, nginx still
proxies to `http://backend:8000`, and the database URL still says 5432. Nothing
inside the network knows or cares. That separation is the reason the remap is a
local convenience and not a change to the application.

The published addresses after the merge:

```text
$ docker compose ps
NAME                                    IMAGE                                 COMMAND                  SERVICE    CREATED          STATUS                    PORTS
13_final_project_taskboard-backend-1    13_final_project_taskboard-backend    "sh -c 'alembic upgr…"   backend    11 seconds ago   Up 5 seconds              127.0.0.1:18000->8000/tcp
13_final_project_taskboard-frontend-1   13_final_project_taskboard-frontend   "/docker-entrypoint.…"   frontend   11 seconds ago   Up 5 seconds              127.0.0.1:13000->80/tcp
13_final_project_taskboard-postgres-1   postgres:16-alpine                    "docker-entrypoint.s…"   postgres   11 seconds ago   Up 11 seconds (healthy)   127.0.0.1:15432->5432/tcp
```

The `127.0.0.1:` prefix is also deliberate, and section 10 explains what forced
it.

![Compose services and the remapped host ports](screenshots/s21-01-stack-and-ports.png)

---

## 4. Build and start

```text
 13_final_project_taskboard-backend  Built
 13_final_project_taskboard-frontend  Built
 Network 13_final_project_taskboard_default  Created
 Volume 13_final_project_taskboard_postgres-data  Created
 Container 13_final_project_taskboard-postgres-1  Starting
 Container 13_final_project_taskboard-postgres-1  Started
 Container 13_final_project_taskboard-postgres-1  Waiting
 Container 13_final_project_taskboard-postgres-1  Healthy
 Container 13_final_project_taskboard-backend-1  Starting
 Container 13_final_project_taskboard-backend-1  Started
 Container 13_final_project_taskboard-frontend-1  Starting
 Container 13_final_project_taskboard-frontend-1  Started
```

`Waiting`, then `Healthy`, then the backend starting is the whole fix from
section 10 visible in four lines of output. Compose created the network and the
volume first, brought up PostgreSQL, blocked on its healthcheck, and only then
released the backend.

---

## 5. The database

The backend applies the migration before uvicorn binds a port:

```text
$ docker compose logs backend --tail=12
backend-1  | INFO  [alembic.runtime.migration] Context impl PostgresqlImpl.
backend-1  | INFO  [alembic.runtime.migration] Will assume transactional DDL.
backend-1  | INFO  [alembic.runtime.migration] Running upgrade  -> 0001_create_tasks
backend-1  | INFO:     Started server process [8]
backend-1  | INFO:     Application startup complete.
backend-1  | INFO:     Uvicorn running on http://0.0.0.0:8000 (Press CTRL+C to quit)
```

Two tables exist afterwards, not one:

```text
$ docker compose exec -T postgres psql -U taskboard -d taskboard -c '\dt'
              List of relations
 Schema |      Name       | Type  |   Owner
--------+-----------------+-------+-----------
 public | alembic_version | table | taskboard
 public | tasks           | table | taskboard
(2 rows)
```

`alembic_version` holds a single row naming the revision that has been applied.
It is what makes `alembic upgrade head` safe to run on every container start:
the second boot reads that row, sees it is already at head, and does nothing.

```text
$ docker compose exec -T postgres psql -U taskboard -d taskboard -c '\d tasks'
                                       Table "public.tasks"
   Column    |           Type           | Collation | Nullable |              Default
-------------+--------------------------+-----------+----------+-----------------------------------
 id          | integer                  |           | not null | nextval('tasks_id_seq'::regclass)
 title       | character varying(200)   |           | not null |
 description | text                     |           | not null | ''::text
 priority    | character varying(20)    |           | not null | 'MEDIUM'::character varying
 status      | character varying(30)    |           | not null | 'TODO'::character varying
 assignee    | character varying(120)   |           | not null | 'Unassigned'::character varying
 created_at  | timestamp with time zone |           | not null |
Indexes:
    "tasks_pkey" PRIMARY KEY, btree (id)
```

Those defaults are `server_default` values set by the migration, so they hold
even for a row inserted by hand in `psql`, not only for one created through
SQLAlchemy. `created_at` has none, because the application computes it in UTC.

![The migrated tasks table in PostgreSQL](screenshots/s21-04-database-schema.png)

---

## 6. The API

### Health, readiness and the service root

```text
$ curl -s http://localhost:18000/ | python3 -m json.tool
{
    "service": "TaskBoard API",
    "version": "1.0.0",
    "docs": "/docs"
}

$ curl -s http://localhost:18000/health | python3 -m json.tool
{
    "status": "UP"
}

$ curl -s http://localhost:18000/ready | python3 -m json.tool
{
    "status": "READY"
}
```

### Create, read, update, delete

The board starts empty, which on a fresh volume it genuinely is:

```text
$ curl -s http://localhost:18000/api/tasks | python3 -m json.tool
[]
```

Three POSTs, each returning the stored row including the server assigned `id`
and `created_at`:

```text
$ curl -s -X POST http://localhost:18000/api/tasks -H 'Content-Type: application/json' -d '{"title":"Write the Dockerfile","description":"multi stage build for the frontend","priority":"HIGH","assignee":"Manasvi"}' | python3 -m json.tool
{
    "title": "Write the Dockerfile",
    "description": "multi stage build for the frontend",
    "priority": "HIGH",
    "status": "TODO",
    "assignee": "Manasvi",
    "id": 1,
    "created_at": "2026-10-07T18:02:16.483043Z"
}
```

Note what the response proves: `status` came back as `TODO` and the POST never
sent one. That is the Pydantic default filling in, not the database.

A PUT on task 1:

```text
$ curl -s -X PUT http://localhost:18000/api/tasks/1 -H 'Content-Type: application/json' -d '{"title":"Write the Dockerfile","status":"DONE","priority":"HIGH","assignee":"Manasvi"}' | python3 -m json.tool
{
    "title": "Write the Dockerfile",
    "description": "multi stage build for the frontend",
    "priority": "HIGH",
    "status": "DONE",
    "assignee": "Manasvi",
    "id": 1,
    "created_at": "2026-10-07T18:02:16.483043Z"
}
```

The `description` survived although the PUT body did not mention it. The
handler uses `model_dump(exclude_unset=True)`, so a field the client omitted is
not the same as a field the client set to empty. A naive PUT that assigns every
column would have silently wiped it.

The stats endpoint recounts from the database rather than tracking a counter:

```text
$ curl -s http://localhost:18000/api/tasks/stats | python3 -m json.tool
{
    "total": 3,
    "todo": 2,
    "inProgress": 0,
    "done": 1
}
```

And a delete, which returns a status code and nothing else:

```text
$ curl -s -o /dev/null -w 'HTTP %{http_code}\n' -X DELETE http://localhost:18000/api/tasks/3
HTTP 204

$ curl -s http://localhost:18000/api/tasks | python3 -m json.tool
[
    {
        "title": "Run docker compose up",
        "description": "",
        "priority": "MEDIUM",
        "status": "TODO",
        "assignee": "Manasvi",
        "id": 2,
        "created_at": "2026-10-07T18:02:16.517583Z"
    },
    {
        "title": "Write the Dockerfile",
        "description": "multi stage build for the frontend",
        "priority": "HIGH",
        "status": "DONE",
        "assignee": "Manasvi",
        "id": 1,
        "created_at": "2026-10-07T18:02:16.483043Z"
    }
]
```

204 means "done, and there is deliberately no body". `curl -s` alone shows
nothing at all, which is why the command asks for `%{http_code}` instead.

![PUT, stats and DELETE returning 204](screenshots/s21-06-update-stats-delete.png)

---

## 7. Error handling

```text
$ curl -s -w '\nHTTP %{http_code}\n' http://localhost:18000/api/tasks/999
{"detail":"Task not found"}
HTTP 404

$ curl -s -w '\nHTTP %{http_code}\n' -X POST http://localhost:18000/api/tasks -H 'Content-Type: application/json' -d '{"priority":"HIGH"}'
{"detail":[{"type":"missing","loc":["body","title"],"msg":"Field required","input":{"priority":"HIGH"}}]}
HTTP 422
```

These two come from different places, and that is the interesting part. The 404
is application code: `db.get` returned nothing and the handler raised
`HTTPException`. The 422 never reached the handler at all, because FastAPI
validated the body against `TaskCreate` first and rejected it. The error names
the exact field and its location in the request, which is free: it falls out of
the type annotation.

422 rather than 400 is correct here. The JSON parsed fine, it just failed the
schema.

---

## 8. Frontend, metrics and tests

### The SPA is served, and the proxy works

```text
$ curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://localhost:13000/
HTTP 200

$ curl -s http://localhost:13000/ | head -20
<!doctype html><html><head><meta charset="UTF-8"/><meta name="viewport" content="width=device-width,initial-scale=1.0"/><title>TaskBoard</title>  <script type="module" crossorigin src="/assets/index-BhFpkPY_.js"></script>
  <link rel="stylesheet" crossorigin href="/assets/index-DkMuKOF6.css">
</head><body><div id="root"></div></body></html>
```

That is the built artefact, not the source: an empty `<div id="root">` and a
hashed bundle name that Vite generated. The hash is a cache busting device, a
new build produces a new filename.

The same container answers API calls by proxying them:

```text
$ curl -s http://localhost:13000/api/tasks | python3 -m json.tool
[
    {
        "title": "Run docker compose up",
        "description": "",
        "priority": "MEDIUM",
        "status": "TODO",
        "assignee": "Manasvi",
        "id": 2,
        "created_at": "2026-10-07T18:02:16.517583Z"
    },
    {
        "title": "Write the Dockerfile",
        "description": "multi stage build for the frontend",
        "priority": "HIGH",
        "status": "DONE",
        "assignee": "Manasvi",
        "id": 1,
        "created_at": "2026-10-07T18:02:16.483043Z"
    }
]
```

Port 13000 is the frontend. There is no backend listening there. The identical
JSON from port 18000 and port 13000 is the proxy doing its job over the compose
network.

![404 and 422, nginx serving the SPA and proxying /api](screenshots/s21-07-errors-and-frontend.png)

### Metrics

```text
$ curl -s http://localhost:18000/metrics | grep -E '^http_requests_total|^http_request_duration' | head -6
http_requests_total{handler="/health",method="GET",status="2xx"} 2.0
http_requests_total{handler="/",method="GET",status="2xx"} 1.0
http_requests_total{handler="/ready",method="GET",status="2xx"} 1.0
http_requests_total{handler="/api/tasks",method="GET",status="2xx"} 4.0
http_requests_total{handler="/api/tasks",method="POST",status="2xx"} 3.0
http_requests_total{handler="/api/tasks/{task_id}",method="GET",status="2xx"} 1.0
```

The `handler` label is the **route template**, `/api/tasks/{task_id}`, not the
concrete path. If it were the concrete path then every task id would create its
own time series and the cardinality would grow without bound. The counts also
match what the script actually sent, which is a cheap independent check that
the requests landed on the service being measured.

### Pytest against the shipped image

```text
$ docker compose exec -T -w /tmp -e DATABASE_URL=sqlite:////tmp/test.db backend python -m pytest -v /app/tests
============================= test session starts ==============================
platform linux -- Python 3.12.15, pytest-8.3.4, pluggy-1.6.0 -- /usr/local/bin/python
rootdir: /app
configfile: pytest.ini
collected 10 items

../app/tests/test_api.py::test_health PASSED                             [ 10%]
../app/tests/test_api.py::test_root PASSED                               [ 20%]
../app/tests/test_api.py::test_create_task_validation PASSED             [ 30%]
../app/tests/test_api.py::test_ready PASSED                              [ 40%]
../app/tests/test_api.py::test_list_tasks_returns_a_list PASSED          [ 50%]
../app/tests/test_api.py::test_get_task_not_found PASSED                 [ 60%]
../app/tests/test_api.py::test_update_task PASSED                        [ 70%]
../app/tests/test_api.py::test_delete_task PASSED                        [ 80%]
======================== 10 passed, 5 warnings in 0.24s ========================
```

Ten passing, run inside the container that would be deployed, against the
interpreter and dependency versions that are actually installed there.

The run is pointed at a throwaway SQLite file in `/tmp` rather than at the live
PostgreSQL, because the suite creates and deletes rows. Running it against the
real database would have left debris in the middle of the walkthrough and
broken the persistence check in the next section.

Two of the five warnings are honest friction worth keeping:

```text
PytestCacheWarning: could not create cache path /app/.pytest_cache/v/cache/nodeids:
[Errno 13] Permission denied: '/app/pytest-cache-files-iayw04xk'
```

That is `USER 10001` working. The application directory is owned by root and
the process cannot write to it, so pytest cannot drop its cache there. The
tests still pass. A writable application directory would be the actual problem,
so this warning is the security control announcing itself.

![Prometheus metrics and pytest inside the container](screenshots/s21-08-metrics-and-pytest.png)

---

## 9. Persistence

```text
$ docker compose restart backend postgres
 Container 13_final_project_taskboard-backend-1  Restarting
 Container 13_final_project_taskboard-postgres-1  Restarting
 Container 13_final_project_taskboard-postgres-1  Started
 Container 13_final_project_taskboard-backend-1  Started

$ curl -s http://localhost:18000/api/tasks | python3 -m json.tool
[
    {
        "title": "Run docker compose up",
        "description": "",
        "priority": "MEDIUM",
        "status": "TODO",
        "assignee": "Manasvi",
        "id": 2,
        "created_at": "2026-10-07T18:02:16.517583Z"
    },
    {
        "title": "Write the Dockerfile",
        "description": "multi stage build for the frontend",
        "priority": "HIGH",
        "status": "DONE",
        "assignee": "Manasvi",
        "id": 1,
        "created_at": "2026-10-07T18:02:16.483043Z"
    }
]

$ docker volume ls | grep -i taskboard
local     13_final_project_taskboard_postgres-data
```

Both containers were stopped and started again, and the `DONE` status set by
the earlier PUT is still there with its original `created_at`. The data lives
in the named volume, which is a separate object with its own lifecycle.
`docker compose down` leaves it alone. Only `down -v` removes it, which is
exactly why the teardown at the end of the script uses plain `down`.

---

## 10. What went wrong, and what fixed it

The blocks in this section are quoted from the failing runs, so they are not in
the current `output.log`: a clean log is the evidence that these are fixed.

### The backend was unreachable on port 18000

The first runs failed from section 5 onwards with `HTTP 000` on every call,
while the frontend answered fine on 13000. `docker compose ps` without `-a`
showed two services and quietly omitted the third, which is the misleading bit.
`-a` told the truth:

```text
13_final_project_taskboard-backend-1   ...   Exited (1) 9 minutes ago
```

The container was not failing to bind a port. It was dead. The logs gave the
reason:

```text
sqlalchemy.exc.OperationalError: (psycopg.OperationalError) connection failed:
connection to server at "172.24.0.2", port 5432 failed: Connection refused
	Is the server running on that host and accepting TCP/IP connections?
```

It resolved `postgres` to `172.24.0.2`, so DNS and the network were fine.
PostgreSQL simply was not listening yet. The short form `depends_on` in the
base file:

```yaml
depends_on:
  - postgres
```

only waits for the dependency's **container to be started**, not for the
process inside it to be ready. PostgreSQL does first boot initialisation on an
empty volume, which takes a couple of seconds. The backend runs
`alembic upgrade head` as its very first act, hit a refused connection, and
`&&` correctly stopped it from starting uvicorn. With no restart policy, it
stayed exited.

The fix is a real readiness signal plus a real wait, both in the override file:

```yaml
postgres:
  healthcheck:
    test: ["CMD-SHELL", "pg_isready -U taskboard -d taskboard"]
    interval: 3s
    timeout: 3s
    retries: 20
    start_period: 5s
backend:
  depends_on: !override
    postgres:
      condition: service_healthy
  restart: unless-stopped
```

`depends_on` also needed `!override`, for the same merge reason as `ports`: the
base file's short list form and the override's map form do not combine, so the
base entry has to be replaced outright. After that, `docker compose up` prints
`Waiting` then `Healthy` before starting the backend, and it has not failed
since. `restart: unless-stopped` is a second line of defence, not the fix: a
crash loop is a worse failure mode than a clean wait.

This is a good illustration that **the obvious reading of the symptom was
wrong**. "Unreachable on 18000" sounds like a port or firewall problem, and the
port mapping was never involved.

### Something on the internet wrote into the board

The first fully green run still looked wrong. The step labelled "GET on an
empty board" returned a task that nothing in the script had created:

```text
[
    {
        "title": "check",
        "description": "",
        "priority": "HIGH",
        "status": "TODO",
        "assignee": "Unassigned",
        "id": 1,
        "created_at": "2026-10-07T18:00:51.293112Z"
    }
]
```

The backend log named the client:

```text
backend-1  | INFO:     167.82.56.223:40901 - "POST /api/tasks HTTP/1.1" 201 Created
```

A public address, not a container on the bridge network. A compose `ports`
entry written as `"18000:8000"` binds `0.0.0.0`, so publishing the port had put
an unauthenticated write API on every interface of this machine, and something
scanning the network found it and posted a task. Everything downstream was then
subtly off: ids shifted by one, the PUT updated the stray row instead of the
intended one, and `stats` reported four tasks.

The fix is to say where to bind, which compose supports directly:

```yaml
ports: !override
  - "127.0.0.1:18000:8000"
```

`docker compose ps` now prints `127.0.0.1:18000->8000/tcp` rather than
`0.0.0.0:18000->8000/tcp, [::]:18000->8000/tcp`, the stack is reachable from
this machine exactly as before, and the rerun from a wiped volume produced the
clean `[]` quoted in section 6. Publishing all three services on loopback is
right for a development stack regardless.

### A transient registry pull failure

One earlier run died during `docker compose up --build` on an IPv6 route
failure reaching Docker Hub. It was not reproducible and succeeded immediately
on retry. Rather than pretend it cannot happen, `verify.sh` now pre-pulls the
four base images with up to three attempts each before the build, so a single
network blip does not cost a full run.

### The tests were not in the image

`docker compose exec backend python -m pytest` originally collected nothing,
because the backend Dockerfile copies `app`, `alembic` and `alembic.ini` and
nothing else. Adding `COPY tests ./tests` and `COPY pytest.ini ./` means the
suite runs against the real artefact. It also has to run with `-w /tmp`, since
`USER 10001` cannot write a SQLite file into the root owned `/app`.

---

## 11. What I took away

- `docker compose ps` hides exited containers. `-a` is the first command to run
  when something is "unreachable", because a missing row looks a lot like a
  healthy one if you are not counting.
- Short form `depends_on` is a start ordering hint, not a readiness guarantee.
  It is enough for a service whose dependency is instantly ready, and useless
  for a database on first boot.
- `pg_isready` plus `condition: service_healthy` turns a race into a wait, and
  the `Waiting` then `Healthy` lines in the compose output make it visible
  instead of implicit.
- Compose merges sequences by appending. For `ports` that silently produces
  both mappings and reintroduces the conflict the override existed to solve.
  `!override` is not a stylistic choice.
- `"18000:8000"` means `0.0.0.0:18000`. On a shared network that is a public
  endpoint, and I have the log line of a stranger's POST to prove it.
- `&&` in a container `CMD` is a design decision: it makes "migration failed"
  mean "do not serve" rather than "serve against the wrong schema".
- Health and readiness are different questions. A readiness check that touches
  the database is useful, a liveness check that does is a restart loop waiting
  for an outage.
- Multi stage is about what the runtime needs, not about aesthetics. The
  frontend image is the size of bare nginx because Node never reaches the final
  stage. The backend has nothing to separate, so a second stage would be
  ceremony.
- `exclude_unset=True` is what separates "not mentioned" from "set to empty" on
  a PUT. The difference is invisible until a field quietly disappears.
- Prometheus labels must be route templates. Concrete paths look identical in a
  three task demo and become unbounded cardinality in production.
- A permission denied warning from pytest inside the container is the non root
  user working. The alarming version would have been silence.

---

## 12. Screenshots

Terminal captures, all rendered straight from [`output.log`](output.log):

| What it shows | Capture |
|---|---|
| Services and the remapped, loopback bound host ports | [s21-01-stack-and-ports.png](screenshots/s21-01-stack-and-ports.png) |
| Build, then `Waiting` and `Healthy` before the backend starts | [s21-02-build-and-start.png](screenshots/s21-02-build-and-start.png) |
| Built image sizes and the Alembic migration on startup | [s21-03-images-and-migration.png](screenshots/s21-03-images-and-migration.png) |
| `alembic_version` and the `tasks` table with its defaults | [s21-04-database-schema.png](screenshots/s21-04-database-schema.png) |
| Root, health, readiness, and a genuinely empty board | [s21-05-health-and-empty-board.png](screenshots/s21-05-health-and-empty-board.png) |
| PUT preserving an unmentioned field, stats, DELETE 204 | [s21-06-update-stats-delete.png](screenshots/s21-06-update-stats-delete.png) |
| 404 and 422, the SPA shell, and `/api` proxied through nginx | [s21-07-errors-and-frontend.png](screenshots/s21-07-errors-and-frontend.png) |
| `/metrics` with route template labels, and 10 passing tests | [s21-08-metrics-and-pytest.png](screenshots/s21-08-metrics-and-pytest.png) |

![Build, then Waiting and Healthy before the backend starts](screenshots/s21-02-build-and-start.png)

![Prometheus metrics and pytest inside the container](screenshots/s21-08-metrics-and-pytest.png)

### Browser captures still to take

The React UI cannot be captured from a terminal log. With the stack up, open
<http://localhost:13000> and take these five:

| # | What to capture | Where |
|---|---|---|
| 1 | The dashboard with the four stat tiles and the task table populated | `http://localhost:13000` |
| 2 | The "New task" modal with the form filled in | the **New task** button, top right |
| 3 | A task row after its status has been advanced | the circular arrow button on a row |
| 4 | The task list filtered to `DONE` | the filter tabs above the table |
| 5 | The interactive API docs listing every endpoint | `http://localhost:18000/docs` |

<!-- browser screenshot: TaskBoard dashboard at localhost:13000 showing the four stat tiles and the populated task table -->

<!-- browser screenshot: the New task modal open with title, description, priority and assignee filled in -->

<!-- browser screenshot: a task row after clicking the advance button, showing the status badge changed -->

<!-- browser screenshot: the task list filtered to DONE using the filter tabs -->

<!-- browser screenshot: the FastAPI Swagger UI at localhost:18000/docs listing every endpoint -->

---

## 13. Reproducing this

```bash
cd 13_Final_Project_TaskBoard
chmod +x verify.sh && ./verify.sh
```

The script builds both images, waits for PostgreSQL to report healthy,
exercises every endpoint, runs the test suite inside the container, restarts
the stack to prove persistence, and writes everything to `output.log`. A first
run takes a few minutes because of the image pulls and the `npm install` in the
frontend build stage. Later runs are much faster, since both are cached.

To work with the stack by hand instead:

```bash
docker compose up -d --build
curl -s http://localhost:18000/health     # {"status":"UP"}
open http://localhost:13000               # the React UI
open http://localhost:18000/docs          # Swagger UI
```

If ports 8000, 3000 and 5432 are free on your machine, you can drop the port
lines from `docker-compose.override.yml` and use the course defaults. Keep the
healthcheck and `condition: service_healthy` though, or the backend will race
PostgreSQL on a first boot exactly as described in section 10.

## 14. Cleanup

```bash
docker compose down -v
```

`down` on its own removes the containers and the network but keeps
`13_final_project_taskboard_postgres-data`, which is what section 9 relies on.
The `-v` is what actually deletes the board. To reclaim the two built images
and the build cache as well:

```bash
docker image rm 13_final_project_taskboard-backend 13_final_project_taskboard-frontend
docker builder prune -f
```
