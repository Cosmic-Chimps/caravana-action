#!/usr/bin/env python3
"""A fake Caravana API for testing caravana-deploy.sh.

    fake_caravana.py PORT_FILE LOG_FILE SCENARIO_FILE

It listens on a free local port (written to PORT_FILE), answers the few
endpoints the action uses with behaviour chosen by the scenario file (JSON),
and writes every request it gets (method, path, headers, body) to LOG_FILE as
a JSON list. Python 3 standard library only.

Scenario keys (all optional; see test/run.sh for the defaults):

  token            the bearer token it accepts; anything else is 401
  delay            seconds each request takes (so a process list can be sampled)
  forbid           true: every request is 403 token_scope
  app              null: no such app (404). Else the AppRecord's parts:
                   defined, revision, stoppedAt, app (the App document)
  deploy           what POST /v1/apps/{id}/deployments does:
    initial          status in the 202 answer (default "pending")
    final            healthy | failed | reverted | superseded | never
    polls            reads that still say "running" before the final status (default 1)
    error            the deployment's error text when it did not end healthy
    warnings         list of {field, message}
    post_error       {status, error} or {status, raw}: answer this instead of deploying
    stale_once       1: the first POST with If-Match answers 412 app_changed and the
                     app takes a new revision (fedcba9876543210)
    always_stale     true: every POST with If-Match answers 412 app_changed
    transient_503    this many 503s on the first reads of the deployment
    absolute_location true: the Location header is a full URL
  promote          what POST /v1/apps/{id}/promote does: target (app ID of the
                   target), initial, final, polls, error, warnings, post_error
"""
import json
import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port_file, log_file, scenario_file = sys.argv[1:4]
with open(scenario_file) as f:
    scenario = json.load(f)

lock = threading.Lock()
log = []
deployments = {}  # id -> {kind, app_id, reads, digests}
counter = {"deploy": 0, "promote": 0}

APP_PATH = re.compile(r"^/v1/apps/([^/]+)$")
DEPLOYMENTS_PATH = re.compile(r"^/v1/apps/([^/]+)/deployments$")
DEPLOYMENT_PATH = re.compile(r"^/v1/apps/([^/]+)/deployments/([^/]+)$")
PROMOTE_PATH = re.compile(r"^/v1/apps/([^/]+)/promote$")

FINAL = ("healthy", "failed", "reverted", "superseded")


def error_body(code, message, field=None):
    err = {"code": code, "message": message}
    if field:
        err["field"] = field
    return {"error": err}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # keep the test output quiet
        pass

    # --- plumbing ---------------------------------------------------------

    def reply(self, status, body=None, headers=None, raw=None):
        if raw is not None:
            data = raw.encode()
            ctype = "text/plain"
        else:
            data = json.dumps(body if body is not None else {}).encode()
            ctype = "application/json"
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def handle_any(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw_body = self.rfile.read(length).decode() if length else ""
        with lock:
            log.append({
                "method": self.command,
                "path": self.path,
                "headers": {k.lower(): v for k, v in self.headers.items()},
                "body": raw_body,
            })
            with open(log_file + ".tmp", "w") as f:
                json.dump(log, f)
            os.replace(log_file + ".tmp", log_file)
            self.route(raw_body)

    do_GET = do_POST = do_PUT = do_DELETE = handle_any

    # --- routes -----------------------------------------------------------

    def route(self, raw_body):
        time.sleep(scenario.get("delay", 0))
        token = scenario.get("token", "")
        if self.headers.get("Authorization") != "Bearer " + token:
            return self.reply(401, error_body("unauthorized", "sign in or send a valid API token"))
        if scenario.get("forbid"):
            return self.reply(403, error_body(
                "token_scope", "this token can only deploy app web of project shop"))

        path = self.path
        if (m := DEPLOYMENT_PATH.match(path)) and self.command == "GET":
            return self.get_deployment(m.group(1), m.group(2))
        if (m := DEPLOYMENTS_PATH.match(path)) and self.command == "POST":
            return self.post_deploy(m.group(1), raw_body)
        if (m := PROMOTE_PATH.match(path)) and self.command == "POST":
            return self.post_promote(m.group(1), raw_body)
        if (m := APP_PATH.match(path)) and self.command == "GET":
            return self.get_app(m.group(1))
        return self.reply(404, error_body("not_found", "no such route in the fake"))

    def get_app(self, app_id):
        rec = scenario.get("app")
        if rec is None:
            return self.reply(404, error_body("app_not_found", "no app %r" % app_id))
        body = {
            "app": rec["app"],
            "defined": rec.get("defined", True),
            "revision": rec.get("revision", "0123456789abcdef"),
            "composeKept": False,
            "createdAt": "2026-10-18T10:00:00Z",
            "updatedAt": "2026-10-18T10:00:00Z",
        }
        if rec.get("stoppedAt"):
            body["stoppedAt"] = rec["stoppedAt"]
        return self.reply(200, body, {"ETag": '"%s"' % body["revision"]})

    def location(self, app_id, dep_id, cfg):
        path = "/v1/apps/%s/deployments/%s" % (app_id, dep_id)
        if cfg.get("absolute_location"):
            return "http://%s%s" % (self.headers.get("Host"), path)
        return path

    def post_deploy(self, app_id, raw_body):
        cfg = scenario.get("deploy", {})
        rec = scenario.get("app")
        if cfg.get("post_error"):
            return self.reply_error(cfg["post_error"])

        if_match = self.headers.get("If-Match")
        if if_match is not None:
            # As Caravana: one quoted revision, like getApp's ETag, else 400.
            if len(if_match) < 2 or not (if_match.startswith('"') and if_match.endswith('"')):
                return self.reply(400, error_body("invalid_field", "must be one quoted revision", "If-Match"))
            if_match = if_match[1:-1]
        if raw_body and if_match:
            current = rec.get("revision", "0123456789abcdef") if rec else None
            if cfg.get("always_stale") or (cfg.get("stale_once", 0) > 0):
                if cfg.get("stale_once", 0) > 0:
                    cfg["stale_once"] -= 1
                    if rec:
                        rec["revision"] = "fedcba9876543210"
                return self.reply(412, error_body("app_changed", "the app changed since you read it"))
            if current is not None and if_match != current:
                return self.reply(412, error_body("app_changed", "the app changed since you read it"))

        if not raw_body:
            if rec is None:
                return self.reply(404, error_body("app_not_found", "no app %r" % app_id))
            if not rec.get("defined", True):
                return self.reply(409, error_body("app_not_defined", "the app has no services yet"))

        digests = {}
        if raw_body:
            doc = json.loads(raw_body)
            for svc in doc.get("services", []):
                img = svc["image"]
                digests[svc["name"]] = img if "@sha256:" in img else img + "@sha256:" + "a" * 64
        elif rec:
            for svc in rec["app"].get("services", []):
                digests[svc["name"]] = svc["image"] + "@sha256:" + "b" * 64

        counter["deploy"] += 1
        dep_id = "dep%d" % counter["deploy"]
        deployments[dep_id] = {"kind": "deploy", "app_id": app_id, "reads": 0, "digests": digests,
                               "transient": cfg.get("transient_503", 0)}
        body = self.deployment_body(dep_id, app_id, cfg.get("initial", "pending"), cfg, digests)
        return self.reply(202, body, {"Location": self.location(app_id, dep_id, cfg)})

    def post_promote(self, app_id, raw_body):
        cfg = scenario.get("promote", {})
        if cfg.get("post_error"):
            return self.reply_error(cfg["post_error"])
        target = cfg.get("target", "shop--production--web")
        counter["promote"] += 1
        dep_id = "prom%d" % counter["promote"]
        digests = {"web": "ghcr.io/acme/web@sha256:" + "c" * 64}
        deployments[dep_id] = {"kind": "promote", "app_id": target, "reads": 0, "digests": digests,
                               "transient": cfg.get("transient_503", 0)}
        body = self.deployment_body(dep_id, target, cfg.get("initial", "pending"), cfg, digests)
        return self.reply(202, body, {"Location": self.location(target, dep_id, cfg)})

    def get_deployment(self, app_id, dep_id):
        dep = deployments.get(dep_id)
        if dep is None or dep["app_id"] != app_id:
            return self.reply(404, error_body("deployment_not_found", "no such deployment"))
        cfg = scenario.get("deploy" if dep["kind"] == "deploy" else "promote", {})
        if dep["transient"] > 0:
            dep["transient"] -= 1
            return self.reply(503, raw="upstream unavailable")
        dep["reads"] += 1
        final = cfg.get("final", "healthy")
        if final == "never" or dep["reads"] <= cfg.get("polls", 1):
            status = "running"
        else:
            status = final
        return self.reply(200, self.deployment_body(dep_id, app_id, status, cfg, dep["digests"]))

    def deployment_body(self, dep_id, app_id, status, cfg, digests):
        body = {
            "id": dep_id,
            "appId": app_id,
            "trigger": "manual",
            "status": status,
            "digests": digests,
            "warnings": cfg.get("warnings", []),
            "definitionRecorded": True,
            "composeKept": False,
            "createdAt": "2026-10-18T10:00:00Z",
            "updatedAt": "2026-10-18T10:00:00Z",
        }
        if status != "pending":
            body["jobVersion"] = 7
        if status in ("failed", "reverted", "superseded"):
            body["error"] = cfg.get("error", "the health check never passed")
        return body

    def reply_error(self, spec):
        if "raw" in spec:
            return self.reply(spec["status"], raw=spec["raw"])
        return self.reply(spec["status"], {"error": spec["error"]})


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
