#!/usr/bin/env python3
# gate-run-test.sh's docker: logs argv and each -f/--env-file source (owner, sha256 read now), and answers
# compose config from the YAML it was given. Its log and probe dir are the directory it was installed in.
import hashlib, json, os, sys
import yaml

here = os.path.dirname(os.path.realpath(__file__))
args = sys.argv[1:]
with open(os.path.join(here, "docker.log"), "a") as log:
    log.write("ARGV " + " ".join(args) + "\n")
    for i, a in enumerate(args[:-1]):
        if a in ("-f", "--env-file"):
            p = args[i + 1]
            st = os.stat(p)
            log.write("FILE %s %s %d %s\n" % (a, p, st.st_uid, hashlib.sha256(open(p, "rb").read()).hexdigest()))
if args[:1] != ["compose"]:
    sys.exit(0)
proj, files, rest, i = os.getcwd(), [], [], 1
while i < len(args):
    a = args[i]
    if a in ("--project-directory", "-p", "-f", "--env-file", "--profile"):
        if a == "--project-directory": proj = args[i + 1]
        if a == "-f": files.append(args[i + 1])
        i += 2
    else:
        rest.append(a); i += 1
skip_override = os.path.exists(os.path.join(here, "ignore-override"))
services = {}
for f in files:
    if skip_override and "/override" in f: continue
    for name, svc in ((yaml.safe_load(open(f)) or {}).get("services") or {}).items():
        out = services.setdefault(name, {})
        for k, v in svc.items():
            if k == "volumes":
                merged = {x["target"]: x for x in out.get("volumes", [])}
                for vol in v:
                    if isinstance(vol, str):
                        parts = vol.split(":")
                        src = parts[0]
                        if src.startswith(".") or src.startswith("/"):
                            vol = {"type": "bind", "source": os.path.normpath(os.path.join(proj, src)), "target": parts[1]}
                        else:
                            vol = {"type": "volume", "source": src, "target": parts[1]}
                        if parts[2:] == ["ro"]: vol["read_only"] = True
                    merged[vol["target"]] = vol
                out["volumes"] = list(merged.values())
            elif k == "build":
                ctx = v if isinstance(v, str) else v.get("context", ".")
                out["build"] = {"context": os.path.normpath(os.path.join(proj, ctx))}
            else:
                out[k] = v
if "config" in rest:
    name = args[args.index("-p") + 1] if "-p" in args else "x"
    print(json.dumps({"name": name, "services": services}))
    sys.exit(0)
if "up" in rest:
    for f in files:
        if "/override" in f:
            for svc in (json.load(open(f)).get("services") or {}).values():
                for v in svc["volumes"]:
                    if v["source"].endswith("/artifacts"): open(os.path.join(v["source"], "report.txt"), "w").write("report\n")
    for marker, target in (("write-tree", "README.md"), ("add-tree", "planted.txt")):
        if os.path.exists(os.path.join(here, marker)):
            with open(os.path.join(proj, target), "a") as w: w.write("container wrote this\n")
if "run" in rest and "--user" in rest:
    build = ""
    for f in files:
        if "/override" in f:
            for svc in (json.load(open(f)).get("services") or {}).values():
                build = next((os.path.dirname(v["source"]) for v in svc["volumes"] if v["source"].endswith("/vendor")), build)
    if build and os.path.exists(os.path.join(here, "plant-build")):
        for d in ("vendor/bin", "node_modules/.bin"):
            os.makedirs(os.path.join(build, d), exist_ok=True)
            p = os.path.join(build, d, "x")
            open(p, "w").write("#!/bin/sh\ntouch %s/pwn\n" % here); os.chmod(p, 0o755)
        os.makedirs(os.path.join(build, "rootonly"), exist_ok=True)
        open(os.path.join(build, "rootonly", "keep"), "w").write("root\n")
        os.rename(os.path.join(build, "vendor"), os.path.join(build, "vendor.old"))
        os.symlink(os.path.join(here, "fake-etc"), os.path.join(build, "vendor"))
