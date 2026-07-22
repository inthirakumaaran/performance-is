# Metering Perf-Test — Agent Handoff

Handoff notes for an agent continuing this work. Covers what exists, why, and
what's unverified. User-facing run instructions live in
[`METERING_TESTING.md`](./METERING_TESTING.md); this file is the engineering context.

---

## 1. Goal & context

Test the WSO2 IS 7.3 **usage metering** component
(`org.wso2.carbon.identity.usage.metering`, source repo at
`/Users/wso2/IAM/MAU/mau`) for **correctness/accuracy + throughput** under load.

Two repos are involved:
- **`/Users/wso2/IAM/MAU/mau`** — the metering OSGi component (product code).
  Builds `target/org.wso2.carbon.identity.usage.metering-1.0.0.jar`. Schema at
  `src/main/resources/db/usage_schema.sql`.
- **`/Users/wso2/IAM/MAU/performance-is`** — WSO2 JMeter perf framework (AWS
  CloudFormation + bash orchestration). **This is where the active integration
  lives.**

**Phase 1 (done):** MAU (via password grant) + M2M token (via client_credentials).
**Phase 2 (not started):** agent login, agent lifecycle CRUD, OBO/direct token.

### How metering works (load-bearing)
Event handler → in-memory cache → **scheduled flush** → DB. Counts appear in the
DB only after a flush. Tables (both in `IDENTITY_DB` via the fallback datasource):
- `IDN_MAU_COUNT` (USER_ID, TENANT_DOMAIN, MONTH_YEAR, LAST_LOGIN) — one row per
  user/tenant/month; MAU = `COUNT(DISTINCT USER_ID)`.
- `IDN_USAGE_COUNT` (NODE_ID, TENANT_DOMAIN, COUNT_TYPE, COUNT, COUNT_PERIOD) —
  M2M/agent counters; cluster-safe accumulate; read via `SUM(COUNT)`.

Key facts (verified in source): handler names `mauLoginEventHandler`,
`m2mTokenUsageHandler`, `agentUsageHandler`; props `flushInterval` +
`flushIntervalUnit` (MAU, MINUTES floor — no seconds), `flushIntervalSeconds`
(M2M/agent), `nodeId` (default `SHA-256(ip:portOffset)`), per-metric
`<key>Publishers`. MAU aggregation into `IDN_USAGE_COUNT` is **calendar-gated**
(month-end 23:xx UTC) so tests assert the intermediate `IDN_MAU_COUNT`. M2M counts
**new tokens only** (`EXISTING_TOKEN_USED != true`). M2M period is stamped at flush
time (UTC hour) → sum across all periods.

---

## 2. Decisions (with rationale)

1. **Integrate into `performance-is`, not a standalone package.** The user found
   running from-scratch AWS scripts hard; reusing the framework is the path.
2. **Tenant mode, 100 tenants × 1000 users** (`-n 100 -u 1000`, framework
   defaults). MAU is per-tenant; `USER_ID` is a global UUID so
   `COUNT(DISTINCT USER_ID)` across all tenants = total distinct users. Scale later
   with `-u 10000`.
3. **Force a new token per M2M request** via a unique `scope` (guarded by
   `-Jmetering=true`). Otherwise IS reuses tokens and the (correct) component skips
   them, making expected counts undefined.
4. **Metering tables in `IDENTITY_DB` (fallback datasource).** No custom
   datasource → **no `identity.xml` / `master-datasource.xml.j2` changes**. This is
   the deliberate minimization.
5. **Omit `nodeId`.** Default per-node SHA gives distinct ids in the cluster, so
   per-node rows sum correctly without per-node config.
6. **Accuracy from the JTL.** Expected is derived from the results `.jtl` (distinct
   `user=` labels for MAU; success count for M2M), compared to DB counts. This is
   robust to random user selection and to dedup.

---

## 3. Changes in `performance-is` (the active work)

Run `git -C /Users/wso2/IAM/MAU/performance-is diff` for exact lines. Summary:

| File | Change |
|------|--------|
| `common/deployment/test_scenarios.sh` | Only scenarios **00** (client_credentials) and **09** (password grant) active, `tenantMode=true`; the other 15 wrapped in a `: <<'DISABLED_SCENARIOS'` heredoc. |
| `common/jmeter/perf-test-is.sh` | (a) `run_tenant_test_data_scripts` script list trimmed to `TestData_Add_Tenants` + `TestData_SCIM2_Add_Tenant_Users` + `TestData_Add_Tenant_OAuth_Apps` (dropped SAML/device/IDP/JWT). (b) Setup path switched from `run_test_data_scripts` to `run_tenant_test_data_scripts`. (c) `jmeter_params += metering=true`. (d) New `report_metering_accuracy` function (auto-runs post-scenario; unzips `results.jtl` from `jtls.zip`, calls `verify-metering.sh`, maps scenario→metric by name). |
| `common/deployment/setup/resources/mysql/create_database.sql` | Appends `CREATE TABLE IF NOT EXISTS IDN_MAU_COUNT` + `IDN_USAGE_COUNT` into `IDENTITY_DB`. **Only MySQL done** — postgres/mssql `create_database.sql` NOT updated (see §6). |
| `single-node/setup/resources/deployment.toml`, `two-node-cluster/setup/resources/deployment.toml` | Appended `[[event_handler]]` blocks for `mauLoginEventHandler` (flush 1 MINUTE) and `m2mTokenUsageHandler` (flush 10s). No `nodeId`. |
| `single-node/run-performance-tests.sh`, `two-node-cluster/run-performance-tests.sh` | `before_execute`: TRUNCATE the two metering tables on RDS. `after_execute`: call `report_metering_accuracy`. |
| `common/jmeter/oauth/OAuth_Client_Credentials_Grant.jmx` | Both thread groups: BeanShell sets `dynScope` (unique when `metering=true`); samplers send `scope=${dynScope}`. |
| `common/jmeter/oidc/OIDC_Password_Grant.jmx` | Both sampler labels now `... user=${username}` so accuracy tooling counts distinct users from the JTL. |
| `common/jmeter/verify-metering.sh` | **New.** Accuracy tool. Placed in `common/jmeter/` so the Maven assembly (`bin.xml`: `../common/jmeter` → `jmeter/`) ships it next to `perf-test-is.sh` (= `$script_dir` on the bastion). |
| `METERING_TESTING.md` | **New.** User-facing setup + run + accuracy doc. |

### Assembly / bastion layout note
`<deployment>/bin.xml` maps `../common/jmeter` → `jmeter/` and `test_scenarios.sh`
→ `jmeter/`. The bastion untars this into `workspace/`; the run script's
`$script_dir` is `workspace/jmeter/`. Anything the run loop references via
`$script_dir` (like `verify-metering.sh`) **must live in `common/jmeter/`**.

---

## 4. The IS 7.3 pack (user action)
**Only required change:** copy the metering JAR into
`repository/components/dropins/` before zipping the pack passed to `-n`. Everything
else is framework-injected. (`identity.xml` / `master-datasource.xml.j2` NOT
needed — fallback datasource.)

---

## 5. How to run + accuracy
```bash
mvn -f /Users/wso2/IAM/MAU/mau/pom.xml clean install     # build JAR -> dropins
cd performance-is/two-node-cluster   # or single-node
./start-performance.sh -k <key.pem> -c <cert> -j <jmeter.tgz> \
                       -n <wso2is-7.3.0-with-metering.zip> -- -d 10 -w 2
```
Accuracy report auto-written to
`results/<scenario>/<heap>/<users>/metering-accuracy.txt` (expected/actual/delta/
accuracy%, gated at ≥99%). Manual: `common/jmeter/verify-metering.sh <mau|m2m>
<results.jtl> <rds_host>`.

---

## 6. Unverified / open items (IMPORTANT for next agent)

1. **Password grant must emit `AUTHENTICATION_SUCCESS`** for MAU to count. Not
   verified on IS 7.3. If a run shows MAU=0, confirm the event the ROPC flow fires
   and adjust the handler `subscriptions`.
2. **`[[event_handler]]` TOML→ModuleConfiguration mapping** on IS 7.3 not verified
   against a live pack (handler names/prop keys are source-confirmed).
3. **Postgres/MSSQL `create_database.sql` NOT updated** — only MySQL. If the run
   uses `-b postgres`/`mssql`, add dialect-appropriate DDL (AUTO_INCREMENT→SERIAL/
   IDENTITY, `ON UPDATE CURRENT_TIMESTAMP`, INDEX syntax) to
   `common/deployment/setup/resources/{postgres,mssql}/create_database.sql`.
4. **`create_database_from_snapshot.sql` path NOT updated.** If `-a true`
   (use_db_snapshot), the metering tables won't be created — add them there too, or
   run `usage_schema.sql` manually.
5. **Nothing has been executed end-to-end** (no AWS/Docker here). All scripts are
   bash/XML-validated and the JTL awk parsers are unit-tested, but a real run is
   the first true test.
6. **MAU month TZ:** `verify-metering.sh` defaults month to UTC (`date -u +%m%Y`);
   `MAUCacheManager` uses server LOCAL time. Fine if IS runs UTC (EC2 default);
   pass an explicit month arg otherwise.

---

## 7. Superseded artifact
`/Users/wso2/IAM/MAU/mau/performance-tests/` — an earlier **standalone** package
(local docker-compose + AWS-from-scratch + shared verify harness + deterministic
metering JMX). Superseded by the `performance-is` integration for AWS, but still
usable as a **fast local-iteration** option (docker-compose IS+MySQL). Its
`common/verify/` harness and JMX are more sophisticated (deterministic user walk,
reuse negative-control) and are a good reference for hardening the framework
version. User has not decided whether to keep or delete it.

---

## 8. Suggested next steps (Phase 2)
- Enable the `agentUsageHandler` block (commented in the mau package's
  `event_handler.toml.snippet`) and add it to the deployment.toml files.
- Author agent scenarios: agent login (`AGENT_LOGIN`, daily), OBO token
  (`AGENT_TOKEN`, hourly — reuse `oauth/Token_Exchange_Grant.jmx` + app-native),
  lifecycle CRUD via SCIM2 on the `AGENT` userstore domain.
- Extend `verify-metering.sh` with `agent_login` / `agent_token` metrics (query
  `IDN_USAGE_COUNT` with the right `COUNT_TYPE` and period granularity).
