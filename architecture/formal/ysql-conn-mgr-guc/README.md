# Formal model of GUC handling in YSQL Connection Manager

TLA+ specifications of how Connection Manager keeps a pooled backend's session
parameters indistinguishable from a dedicated PostgreSQL backend. Each module pairs a
reference model (one backend per client, PostgreSQL's own GUC rules) with a model of
Connection Manager plus the pool, and TLC checks invariants stating that a client cannot
tell the two apart.

| Module | Covers |
|---|---|
| `GucSession.tla` | SET / SET LOCAL / RESET / RESET ALL, transaction end, attach, deploy, the `'G'`/`'g'` default packets and the `'r'` ParameterStatus flags |
| `GucVersioning.tla` | ALTER ... SET, SIGHUP, logical client version assignment and matching, the three adoption strategies, stale-backend expiry |

`SPEC_PLAN.md` is the modelling plan with the code anchors each action was taken from.
`RESULTS.md` / `RESULTS-versioning.md` record what passed, at which bounds, and the
interpretation of every counterexample.

## Running

TLC needs Java 17+ and `tla2tools.jar` from the TLA+ release page.

```
TLA_JAR=~/tools/tla/tla2tools.jar JAVA=/usr/lib/jvm/zulu-17.jdk/bin/java ./run.sh
TLA_JAR=~/tools/tla/tla2tools.jar JAVA=/usr/lib/jvm/zulu-17.jdk/bin/java ./run-versioning.sh
```

Design background: "GUC Variables with YSQL Connection Manager" and "DB DS: GUCs in
Connection Manager" (internal design docs); the hand proof there is what these modules
mechanise for small bounds.
