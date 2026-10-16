// =============================================================================
// Jenkinsfile - ShopLite performance pipeline (capstone, Episode 20)
//
//   GitHub -> Jenkins controller (192.168.0.11) -> Windows agent [windows && jmeter]
//          -> JMeter 5.6.3 CLI -> JTL -> quality gate -> HTML dashboard -> archived artifacts
//
// Every stage runs on a WINDOWS agent, so we use 'bat' (cmd.exe) and 'powershell'
// (Windows PowerShell 5.1). Never 'sh' here: the agent's OS decides the shell, not the
// controller's OS.
//
// Plugins used: Pipeline, Git, Timestamper, HTML Publisher, JUnit, Workspace Cleanup.
// =============================================================================
pipeline {
    // Run on a node that has BOTH labels. The controller has no such labels, so load never
    // lands on it by accident (Episode 17).
    agent { label 'windows && jmeter' }

    parameters {
        choice(name: 'TEST_NAME', choices: ['smoke', 'regression'],
               description: 'Folder under tests/ - smoke = quick health check, regression = full user journey')
        choice(name: 'TARGET_ENV', choices: ['lab', 'local', 'staging'],
               description: 'lab = ShopLite on the Mac 192.168.0.19:8081; local = same machine as JMeter. Loads config/env/<TARGET_ENV>.properties')
        string(name: 'TARGET_HOST', defaultValue: '', description: 'Optional: override the host from the env file')
        string(name: 'TARGET_PORT', defaultValue: '', description: 'Optional: override the port from the env file')
        string(name: 'USERS',    defaultValue: '5',   description: 'Concurrent virtual users (threads)')
        string(name: 'RAMP_UP',  defaultValue: '10',  description: 'Seconds to start all users')
        string(name: 'DURATION', defaultValue: '60',  description: 'Seconds (duration-based plans: regression)')
        string(name: 'LOOPS',    defaultValue: '3',   description: 'Iterations per user (loop-based plans: smoke)')
        string(name: 'THINK_MS', defaultValue: '300', description: 'Think time between requests (ms)')
        string(name: 'MAX_ERROR_PCT', defaultValue: '1',    description: 'FAIL the build above this error %')
        string(name: 'MAX_P95_MS',    defaultValue: '1000', description: 'FAIL the build above this 95th percentile (ms)')
        string(name: 'WARN_P95_MS',   defaultValue: '500',  description: 'Mark UNSTABLE above this 95th percentile (ms); 0 = off')
    }

    options {
        timestamps()                                    // time on every console line
        timeout(time: 30, unit: 'MINUTES')              // a hung load test must not block the agent forever
        buildDiscarder(logRotator(numToKeepStr: '30', artifactNumToKeepStr: '10'))
        disableConcurrentBuilds()                       // two load tests at once would distort both
    }

    environment {
        // Where this run writes JTL, log and dashboard. Backslashes are escaped for Groovy.
        RESULTS_DIR = "${WORKSPACE}\\results\\${params.TEST_NAME}"
    }

    stages {
        stage('Pre-flight') {
            steps {
                // Fails in seconds if Java/JMeter/target are missing - before we spend minutes testing
                withEnv(runEnv(params)) {
                    powershell ".\\scripts\\check-agent-prereqs.ps1 -TargetEnv '${params.TARGET_ENV}'"
                }
            }
        }

        stage('Run JMeter') {
            steps {
                // The batch file reads its settings from environment variables. We pass them
                // EXPLICITLY with withEnv: on the very first build of a parameterised Pipeline, Jenkins
                // has not registered the parameters yet - params.X still returns the default, but the
                // parameters are NOT exported as environment variables (Episode 12).
                // 'call' is not needed here: the bat step runs our line in its own cmd.exe.
                withEnv(runEnv(params)) {
                    bat "scripts\\run-jmeter.bat ${params.TEST_NAME}"
                }
            }
        }

        stage('Quality gate') {
            steps {
                script {
                    // JMeter exits 0 even when every request fails, so the verdict comes from here.
                    // validate-jtl.ps1: 0 = pass, 1 = fail, 2 = bad input, 3 = warn
                    def rc = powershell(returnStatus: true, script: """
                        .\\scripts\\validate-jtl.ps1 -JtlPath "\$env:RESULTS_DIR\\results.jtl" `
                            -MaxErrorPct ${params.MAX_ERROR_PCT} -MaxP95Ms ${params.MAX_P95_MS} -WarnP95Ms ${params.WARN_P95_MS}
                        exit \$LASTEXITCODE
                    """)
                    if (rc == 3) {
                        unstable("Quality gate: warning thresholds breached (p95 > ${params.WARN_P95_MS} ms)")
                    } else if (rc != 0) {
                        error("Quality gate FAILED (exit code ${rc}) - see quality-gate.md in the build artifacts")
                    }
                }
            }
        }
    }

    post {
        always {
            // Keep the evidence even (especially!) when the build failed.
            archiveArtifacts artifacts: 'results/**', allowEmptyArchive: true
            junit testResults: 'results/**/quality-gate-junit.xml', allowEmptyResults: true
            publishHTML(target: [
                reportName           : 'JMeter Dashboard',
                reportDir            : "results/${params.TEST_NAME}/html-report",
                reportFiles          : 'index.html',
                keepAll              : true,
                alwaysLinkToLastBuild: true,
                allowMissing         : true
            ])
        }
        success  { echo 'Performance is within the agreed thresholds.' }
        unstable { echo 'Performance degraded past a WARNING threshold - review the dashboard.' }
        failure  { echo 'Build failed - read the first error in the console, then quality-gate.md.' }
        cleanup {
            // Results are archived above; the workspace copy is no longer needed.
            cleanWs(deleteDirs: true, notFailBuild: true, patterns: [[pattern: 'results/**', type: 'INCLUDE']])
        }
    }
}

// Build the environment for the JMeter scripts from the job parameters.
// Optional overrides are only added when filled in: an empty TARGET_HOST must mean
// "use the env file", not "connect to an empty host name".
def runEnv(p) {
    def e = ["TARGET_ENV=${p.TARGET_ENV}", "USERS=${p.USERS}", "RAMP_UP=${p.RAMP_UP}",
             "DURATION=${p.DURATION}", "LOOPS=${p.LOOPS}", "THINK_MS=${p.THINK_MS}"]
    if (p.TARGET_HOST?.trim()) { e << "TARGET_HOST=${p.TARGET_HOST.trim()}" }
    if (p.TARGET_PORT?.trim()) { e << "TARGET_PORT=${p.TARGET_PORT.trim()}" }
    return e
}
