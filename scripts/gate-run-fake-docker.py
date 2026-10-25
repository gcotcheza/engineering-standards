#!/usr/bin/env python3
# gate-run-test.sh's docker: logs argv and each -f/--env-file source (owner, sha256 read now) and answers compose config
# from the YAML it was given; container writes run as --user. Its log and probe dir are the directory it is installed in.
import hashlib, json, os, re, sys
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
if "-p" in args and not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", args[args.index("-p") + 1]):
    sys.exit("invalid project name %r" % args[args.index("-p") + 1])
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
def as_user(uid_gid, fn):
    pid = os.fork()
    if pid == 0:
        try:
            if os.getuid() == 0 and uid_gid:
                uid, gid = (int(x) for x in uid_gid.split(":"))
                os.setgroups([]); os.setgid(gid); os.setuid(uid)
            fn(); os._exit(0)
        except OSError as e:
            with open(os.path.join(here, "docker.log"), "a") as log: log.write("DENIED %s\n" % e.strerror)
            os._exit(1)
    return os.waitpid(pid, 0)[1] == 0
def override_sources(suffix):
    return [v["source"] for f in files if "/override" in f for svc in (json.load(open(f)).get("services") or {}).values()
            for v in svc["volumes"] if v["source"].endswith(suffix)]
skip_override = os.path.exists(os.path.join(here, "ignore-override"))
services, top = {}, {"volumes": {}, "networks": {}}
for f in files:
    if skip_override and "/override" in f: continue
    doc = yaml.safe_load(open(f)) or {}
    for kind in top:
        for key, v in (doc.get(kind) or {}).items():
            top[kind][key] = dict(v or {})
    for name, svc in (doc.get("services") or {}).items():
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
    for kind in top:
        for key, v in top[kind].items():
            v.setdefault("name", name + "_" + key)
    if os.path.exists(os.path.join(here, "deep-bind")):
        for svc in services.values():
            for v in svc.get("volumes", []):
                if v["source"].endswith("/vendor"): v["source"] += "/sub"
    print(json.dumps({"name": name, "services": services, **{k: v for k, v in top.items() if v}}))
    sys.exit(0)
if "up" in rest or "run" in rest:
    for name, svc in services.items():
        vols = svc.get("volumes", [])
        for p in (x for x in vols if x.get("type") == "bind" and x.get("read_only")):
            for v in vols:
                if v["target"].startswith(p["target"].rstrip("/") + "/") and not os.path.isdir(os.path.join(p["source"], v["target"][len(p["target"].rstrip("/")) + 1:])):
                    sys.exit("make mountpoint %s: read-only file system" % v["target"])
if "up" in rest:
    swap = os.path.join(here, "swap-build")
    for src in override_sources("/artifacts"):
        if os.path.exists(swap):
            ok = as_user(open(swap).read().strip(), lambda: (os.rename(src, src + ".old"), os.symlink(os.path.join(here, "fake-etc"), src)))
            open(os.path.join(here, "docker.log"), "a").write("SWAP %s\n" % ("done" if ok else "refused"))
        open(os.path.join(src, "report.txt"), "w").write("report\n")
    for marker, target in (("write-tree", "README.md"), ("add-tree", "ignored.log")):
        if os.path.exists(os.path.join(here, marker)):
            with open(os.path.join(proj, target), "a") as w: w.write("container wrote this\n")
if "run" in rest and os.path.exists(os.path.join(here, "plant-build")):
    user = rest[rest.index("--user") + 1] if "--user" in rest else ""
    for vendor in override_sources("/vendor"):
        build = os.path.dirname(vendor)
        os.makedirs(os.path.join(vendor, "rootonly"), exist_ok=True)
        open(os.path.join(vendor, "rootonly", "keep"), "w").write("docker wrote this as its own uid\n")
        def plant():
            for d in ("vendor/bin", "node_modules/.bin"):
                os.makedirs(os.path.join(build, d), exist_ok=True)
                p = os.path.join(build, d, "x")
                open(p, "w").write("#!/bin/sh\ntouch %s/pwn\n" % here); os.chmod(p, 0o755)
            os.symlink(os.path.join(here, "fake-etc"), os.path.join(vendor, "etc"))
        as_user(user, plant)
