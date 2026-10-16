# Windows JMeter + Jenkins Lab

A hands-on course that takes Apache JMeter from "I run it by hand" to a **native Windows Jenkins**
pipeline: GitHub → Jenkins controller → Windows agent → JMeter CLI → JTL → quality gate →
HTML dashboard → archived artifacts.

> Companion to the Docker/macOS lab [jenkins-with-jmeter](https://github.com/vasanthshanmugam/jenkins-with-jmeter).
> This one is **Windows-native**: Windows services, `bat`, PowerShell, Windows agents.

## Lab topology

| Role | Machine | What runs there |
|---|---|---|
| Jenkins controller | Windows 11, `192.168.0.11` | Jenkins 2.580.1 LTS as a Windows service (account `svc-jenkins`, Temurin 21), **0 executors** |
| JMeter execution agent + demo GUI | Windows 11 trainer laptop | Inbound WebSocket agent `win-jmeter-01` (labels `windows jmeter`), JMeter 5.6.3, Java 21 |
| System under test | macOS, `192.168.0.19` | ShopLite API in Docker, port `8081` (`demo-app/`) |
| Source control | GitHub | this repository |

```
 GitHub ──► Jenkins controller (.11) ──WebSocket──► Windows agent (laptop) ──HTTP load──► ShopLite (.19:8081)
                 ▲  orchestrates, stores history          runs jmeter.bat -n, validates JTL
                 └──────────── results, dashboard, quality-gate verdict ◄──┘
```

## Quick start

```powershell
# On the JMeter machine (PowerShell), with JMeter 5.6.3 in C:\tools and Java 21:
$env:JMETER_HOME = 'C:\tools\apache-jmeter-5.6.3'
.\scripts\run-jmeter.ps1 -TestName smoke -TargetEnv lab
.\scripts\validate-jtl.ps1 -JtlPath results\smoke\results.jtl -MaxErrorPct 1 -MaxP95Ms 1000
```

```bat
rem Same from CMD
set JMETER_HOME=C:\tools\apache-jmeter-5.6.3
set TARGET_ENV=lab
scripts\run-jmeter.bat regression
```

In Jenkins: job **shoplite-performance** (Pipeline from SCM → `Jenkinsfile`) → *Build with Parameters*.

## Repository layout

| Path | Contents |
|---|---|
| `Jenkinsfile` | Capstone pipeline: pre-flight → JMeter → quality gate → archive / JUnit / HTML dashboard |
| `tests/smoke`, `tests/regression` | JMeter 5.6.3 test plans, fully parameterised with `${__P(...)}` |
| `data/` | CSV test data (users, products) |
| `config/` | `jmeter-ci.properties` (result format, dashboard settings) and `env/*.properties` per target |
| `scripts/run-jmeter.bat` / `.ps1` | Batch and PowerShell wrappers for non-GUI runs |
| `scripts/validate-jtl.ps1` | Quality gate: error %, p95, average → exit 0 / 1 (fail) / 3 (unstable) + Markdown, JSON, JUnit |
| `scripts/check-agent-prereqs.ps1` | Pre-flight check of Java, JMeter, disk, memory and target |
| `scripts/admin/` | Controller setup: Java 21, Git, service account, Jenkins MSI, firewall, health check |
| `scripts/agent/` | Agent setup: JMeter install, agent as a Windows service (WinSW) |
| `demo-app/` | ShopLite API (single Java 21 file) + Dockerfile + docker-compose |
| `docs/` | Instructor guide, 20 episodes + advanced modules, student workbook, troubleshooting |

## Versions used and verified

| Tool | Version |
|---|---|
| Jenkins | 2.580.1 LTS (MSI), Java 21 (Temurin 21.0.12.1) |
| Apache JMeter | 5.6.3 |
| Java on agent | Temurin 21.0.12.1 |
| Git for Windows | 2.56.0 |
| WinSW (agent service) | 2.12.0 |

Only load-test systems you own or are explicitly authorised to test. The ShopLite API in
`demo-app/` exists so the whole course has a safe target.
