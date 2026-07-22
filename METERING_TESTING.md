# Usage Metering — Performance & Accuracy Testing

This fork of the performance framework is wired to test the WSO2 IS 7.3 **usage
metering** component (`org.wso2.carbon.identity.usage.metering`) for **MAU** and
**M2M token** counting, and to **measure the accuracy** of the recorded counts.

Only two scenarios run:

| # | Scenario | Grant | Metering exercised |
|---|----------|-------|--------------------|
| 00 | `oauth/OAuth_Client_Credentials_Grant.jmx` | client_credentials | `M2M_TOKEN` (new tokens) |
| 09 | `oidc/OIDC_Password_Grant.jmx` | password | `MAU` (`AUTHENTICATION_SUCCESS`) |

Both run in **tenant mode: 100 tenants × 1000 users** (framework defaults
`-n 100 -u 1000`).

---

## 1. What was changed in *this framework* (already done)

You don't need to touch these — they're committed here:

- **`common/deployment/test_scenarios.sh`** — only scenarios 00 and 09 are active
  (`tenantMode=true`); all others are moved into a disabled block.
- **`common/jmeter/perf-test-is.sh`**
  - Test-data setup trimmed to **tenants + tenant users + tenant OAuth apps only**
    (SAML / device-flow / IDP / JWT-token setup removed → no unused artifacts).
  - Switched the setup path to `run_tenant_test_data_scripts` (tenant mode).
  - Adds `-Jmetering=true` to every scenario run.
  - New `report_metering_accuracy` helper (auto-runs after each scenario).
- **`common/deployment/setup/resources/mysql/create_database.sql`** — creates the
  two metering tables **inside `IDENTITY_DB`** (`IDN_MAU_COUNT`, `IDN_USAGE_COUNT`).
- **`single-node` & `two-node-cluster` `deployment.toml`** — the metering
  `[[event_handler]]` blocks (short flush intervals).
- **`*/run-performance-tests.sh`** — truncate metering tables before each scenario;
  run the accuracy check after each scenario.
- **JMX tweaks (surgical, backward-compatible):**
  - `OAuth_Client_Credentials_Grant.jmx`: unique `scope` per request when
    `-Jmetering=true`, so each call mints a **new** (countable) token.
  - `OIDC_Password_Grant.jmx`: the sample label now carries `user=${username}`
    so accuracy tooling can count distinct authenticated users from the JTL.

---

## 2. What YOU change in the IS 7.3 pack

**Only one change is required: add the metering JAR.** Everything else is handled
by the framework.

### 2.1 Add the metering bundle (REQUIRED)

Drop the OSGi bundle into the pack **before zipping** the IS distribution you pass
to `-n`:

```bash
cp org.wso2.carbon.identity.usage.metering-1.0.0.jar \
   wso2is-7.3.0/repository/components/dropins/
# then zip wso2is-7.3.0 -> wso2is.zip (the -n argument)
```

> It must go in **`dropins/`**, not `lib/` — it is an OSGi bundle.

### 2.2 deployment.toml (already injected — shown for reference)

The framework overwrites the pack's `deployment.toml` with its own
(`<deployment>/setup/resources/deployment.toml`), which now contains:

```toml
[[event_handler]]
name = "mauLoginEventHandler"
subscriptions = ["AUTHENTICATION_SUCCESS"]
[event_handler.properties]
flushInterval      = "1"
flushIntervalUnit  = "MINUTES"   # MINUTES is the product floor for MAU
cacheRetentionDays = "40"
dbRetentionDays    = "60"
mauPublishers      = "db"

[[event_handler]]
name = "m2mTokenUsageHandler"
subscriptions = ["POST_ISSUE_ACCESS_TOKEN_V2"]
[event_handler.properties]
flushIntervalSeconds = "10"
m2mTokenPublishers   = "db"
```

`nodeId` is **omitted on purpose**: it defaults to `SHA-256(ip:portOffset)`, so in
the 2-node cluster each node gets a distinct id automatically and their counts sum
correctly at read time.

> If you run IS **manually** (outside this framework), add the blocks above to your
> pack's `deployment.toml` yourself.

### 2.3 identity.xml — NOT needed

The metering component uses a custom datasource **only if**
`Server/UsageTracking/DataSourceName` is set in `identity.xml`. We deliberately
leave it unset, so it **falls back to the identity DB (`IDENTITY_DB`)**. No
`identity.xml` change.

### 2.4 master-datasource.xml.j2 — NOT needed

No new datasource is defined, so there is nothing to add to
`master-datasource.xml.j2` (or any `.j2` template). Editing `.j2` templates
directly is unnecessary anyway — `deployment.toml` is the source of truth and IS
regenerates the XML from it on boot.

### 2.5 Identity DB script — handled by the framework

The framework's `create_database.sql` creates `IDN_MAU_COUNT` and
`IDN_USAGE_COUNT` in `IDENTITY_DB` before IS starts. For a **manual** setup, run
`mau/src/main/resources/db/usage_schema.sql` against your identity DB.

**Summary — required IS-pack change is just the JAR (2.1).** The datasource
(2.3/2.4) items you listed are intentionally *not* required with the fallback
approach.

---

## 3. Running the tests

Build the JAR first:

```bash
mvn -f /Users/wso2/IAM/MAU/mau/pom.xml clean install
# -> target/org.wso2.carbon.identity.usage.metering-1.0.0.jar  (put in dropins, §2.1)
```

### Basic (single node)

```bash
cd single-node
./start-performance.sh -k <key.pem> -c <cert-name> -j <apache-jmeter-*.tgz> \
                       -n <wso2is-7.3.0-with-metering.zip> \
                       -- -d 10 -w 2
```

### 2-node cluster

```bash
cd two-node-cluster
./start-performance.sh -k <key.pem> -c <cert-name> -j <apache-jmeter-*.tgz> \
                       -n <wso2is-7.3.0-with-metering.zip> \
                       -- -d 10 -w 2
```

Data scale is controlled by flags after `--` (passed to `run-performance-tests.sh`
→ `perf-test-is.sh`):

| Flag | Meaning | Default |
|------|---------|---------|
| `-u` | users **per tenant** | `1000` |
| `-n` | tenants | `100` |
| `-c` | concurrent-user levels | e.g. `"50 100 300"` |
| `-d` | test duration (min) | |
| `-w` | warm-up (min) | |

**First simple run = defaults (1000 users × 100 tenants).**
**Later 10 000 users:** add `-u 10000` (keep `-n 100`) → 1M users provisioned;
expect a much longer setup phase.

---

## 4. Measuring accuracy

After each scenario the framework runs `common/jmeter/verify-metering.sh` and
writes `results/<scenario>/<heap>/<users>/metering-accuracy.txt`. It compares what
JMeter actually did against what the DB recorded:

- **MAU**: `expected` = distinct `user=<name>` labels among successful JTL samples
  (the password-grant sample label carries the username). `actual` =
  `COUNT(DISTINCT USER_ID)` in `IDN_MAU_COUNT` for the month. `USER_ID` is a
  globally-unique UUID, so this correctly sums distinct users across all tenants.
- **M2M**: `expected` = successful (HTTP 200) client_credentials samples (each
  mints a new token thanks to the unique scope). `actual` = `SUM(COUNT)` for
  `COUNT_TYPE='M2M_TOKEN'` across all periods and nodes.

Output:

```
metric   : MAU distinct users (month 072026)
expected : 100000
actual   : 100000
delta    : 0
accuracy : 100.00%
RESULT: PASS (>= 99% and no over-count)
```

The check waits for the async flush to settle before reading (poll-until-stable),
and gates on `THRESHOLD` (default 99%). Run it manually on the bastion too:

```bash
# on the bastion, against the RDS
common/jmeter/verify-metering.sh mau results/09-oidc_password_grant/.../results.jtl <rds_host>
common/jmeter/verify-metering.sh m2m results/00-oauth_client_credential_grant/.../results.jtl <rds_host>
```

### Why accuracy could read below 100%
- **MAU**: metering counts a user once/month (dedup). Because `expected` is derived
  from the *distinct* usernames in the JTL, repeated logins don't inflate it —
  so a correct component reads ~100%. A shortfall means lost increments across the
  cache→flush pipeline.
- **M2M**: without the unique scope, IS reuses tokens and the component (correctly)
  doesn't count reuses — which is why `-Jmetering=true` forces new tokens so the
  expected value is well-defined.

---

## 5. Validate on first run (component-behaviour assumptions)

- **Password grant fires `AUTHENTICATION_SUCCESS`.** MAU listens to that event; if
  IS 7.3 password grant emits it, MAU increments. If the first run shows MAU=0,
  confirm the event name the ROPC flow emits and adjust the `subscriptions` in the
  handler config.
- **`[[event_handler]]` TOML mapping** for IS 7.3 (name → handler, subscriptions).
- **client_credentials + unique scope** yields a new token each call (expected in
  7.3; the scope-uniqueness guarantees it regardless of token-reuse config).
