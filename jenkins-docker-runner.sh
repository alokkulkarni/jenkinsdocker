# Create a simpler initial trigger function
cat > "$TEMP_DIR/scripts/direct-trigger.sh" << EOSH
#!/bin/bash
set -ex

# This script provides a direct way to trigger a job using Jenkins CLI
# It's a fallback if the Groovy-based triggering doesn't work

JOB_NAME="$JOB_NAME"
JENKINS_URL="http://localhost:8085"
JENKINS_USER="$JENKINS_ADMIN_USER"
JENKINS_PASSWORD="$JENKINS_ADMIN_PASSWORD"

# Create a directory for temporary files
mkdir -p /tmp/jenkins-cli

# Wait for Jenkins to become available
for i in {1..30}; do
  if curl -s -o /dev/null -u "\$JENKINS_USER:\$JENKINS_PASSWORD" "\$JENKINS_URL"; then
    break
  fi
  sleep 2
  echo "Waiting for Jenkins to start... (\$i/30)"
done

# Download Jenkins CLI
curl -s -o /tmp/jenkins-cli/jenkins-cli.jar "\$JENKINS_URL/jnlpJars/jenkins-cli.jar"

# Trigger job using CLI
java -jar /tmp/jenkins-cli/jenkins-cli.jar -s "\$JENKINS_URL" -auth "\$JENKINS_USER:\$JENKINS_PASSWORD" build "\$JOB_NAME" -s -v || true

# Alternative method using HTTP API
echo "Triggering build via HTTP API as fallback..."
CRUMB=\$(curl -s -u "\$JENKINS_USER:\$JENKINS_PASSWORD" "\$JENKINS_URL/crumbIssuer/api/json" | grep -o '"crumb":"[^"]*' | cut -d':' -f2 | tr -d '"')

if [ -n "\$CRUMB" ]; then
  curl -X POST -u "\$JENKINS_USER:\$JENKINS_PASSWORD" -H "Jenkins-Crumb: \$CRUMB" "\$JENKINS_URL/job/\$JOB_NAME/build?delay=0sec"
  echo "Job triggered via HTTP API"
else
  # Final attempt without crumb (in case crumb issuer is disabled)
  curl -X POST -u "\$JENKINS_USER:\$JENKINS_PASSWORD" "\$JENKINS_URL/job/\$JOB_NAME/build?delay=0sec"
  echo "Job triggered via HTTP API without crumb"
fi

# Create a marker file to indicate this script was executed
touch /var/jenkins_home/direct-trigger-executed
EOSH

chmod 755 "$TEMP_DIR/scripts/direct-trigger.sh"#!/bin/bash
#
# Jenkins Docker Runner
# ---------------------
# A script to run Jenkins in a Docker container with a pipeline configured from a Jenkinsfile.
# Supports JCasC configuration, custom plugins, and automatic pipeline execution.
#

set -e

# Default values
JENKINS_HOME="/var/jenkins_home"
JENKINSFILE="Jenkinsfile"
PLUGINS_FILE="plugins.txt"
JCASC_FILE="jenkins.yaml"
JENKINS_IMAGE="jenkins/jenkins:lts-jdk17"
DOCKER_NETWORK="jenkins-network"
CONTAINER_NAME="jenkins-runner"
PORT="8085"
AGENT_PORT="50000"
JOB_NAME="pipeline-job"
POLL_INTERVAL=2
MAX_WAIT_TIME=600  # 10 minutes
LOGS_DIR="./jenkins_logs"
JENKINS_ADMIN_USER="admin"
JENKINS_ADMIN_PASSWORD="admin123"
KEEP_CONTAINER=false
SKIP_CLEANUP=false
DEBUG_MODE=false

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Help function
function show_help {
  echo -e "${BLUE}Jenkins Docker Runner${NC}"
  echo "Usage: $0 [options]"
  echo ""
  echo "Options:"
  echo "  -f, --jenkinsfile FILE     Path to Jenkinsfile (default: ./Jenkinsfile)"
  echo "  -p, --plugins FILE         Path to plugins.txt file (default: ./plugins.txt)"
  echo "  -c, --casc FILE            Path to JCasC yaml file (default: ./jenkins.yaml)"
  echo "  -i, --image IMAGE          Jenkins Docker image (default: jenkins/jenkins:lts-jdk17)"
  echo "  -n, --name NAME            Container name (default: jenkins-runner)"
  echo "  -j, --job-name NAME        Job name (default: pipeline-job)"
  echo "  -P, --port PORT            Web UI port (default: 8080)"
  echo "  -a, --agent-port PORT      Agent port (default: 50000)"
  echo "  -l, --logs-dir DIR         Directory to save logs (default: ./jenkins_logs)"
  echo "  -u, --user USER            Jenkins admin username (default: admin)"
  echo "  -w, --password PASSWORD    Jenkins admin password (default: admin123)"
  echo "  -k, --keep                 Keep container running after job execution"
  echo "  -s, --skip-cleanup         Skip cleanup on failure (for debugging)"
  echo "  -d, --debug                Enable debug mode with verbose output"
  echo "  -h, --help                 Show this help message"
  exit 0
}

# Log functions
function log_info {
  echo -e "${GREEN}[INFO]${NC} $1"
}

function log_warn {
  echo -e "${YELLOW}[WARNING]${NC} $1"
}

function log_error {
  echo -e "${RED}[ERROR]${NC} $1" >&2
}

function log_debug {
  if [ "$DEBUG_MODE" = true ]; then
    echo -e "${BLUE}[DEBUG]${NC} $1"
  fi
}

# Error handling function
function error_exit {
  log_error "$1"
  if [ "$SKIP_CLEANUP" = false ]; then
    cleanup
  else
    log_info "Skipping cleanup as requested. Container and volumes left intact for debugging."
  fi
  exit 1
}

# Function to clean up container and volumes
function cleanup {
  log_info "Cleaning up resources..."
  # Stop and remove container
  if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    log_info "Stopping and removing container: $CONTAINER_NAME"
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
  
  # Remove volume
  if docker volume ls --format '{{.Name}}' | grep -q "^${CONTAINER_NAME}_data$"; then
    log_info "Removing volume: ${CONTAINER_NAME}_data"
    docker volume rm "${CONTAINER_NAME}_data" >/dev/null 2>&1 || true
  fi
}

# Function to handle script termination
function handle_exit {
  if [ "$KEEP_CONTAINER" = true ]; then
    log_info "Container $CONTAINER_NAME kept running at user request."
    log_info "You can access Jenkins at http://localhost:$PORT"
    log_info "Username: $JENKINS_ADMIN_USER"
    log_info "Password: $JENKINS_ADMIN_PASSWORD"
    log_info "To manually stop and remove the container later, run:"
    echo "  docker stop $CONTAINER_NAME && docker rm $CONTAINER_NAME"
    log_info "To remove the volume, run:"
    echo "  docker volume rm ${CONTAINER_NAME}_data"
  else
    cleanup
  fi
  exit $1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    -f|--jenkinsfile)
      JENKINSFILE="$2"
      shift 2
      ;;
    -p|--plugins)
      PLUGINS_FILE="$2"
      shift 2
      ;;
    -c|--casc)
      JCASC_FILE="$2"
      shift 2
      ;;
    -i|--image)
      JENKINS_IMAGE="$2"
      shift 2
      ;;
    -n|--name)
      CONTAINER_NAME="$2"
      shift 2
      ;;
    -j|--job-name)
      JOB_NAME="$2"
      shift 2
      ;;
    -P|--port)
      PORT="$2"
      shift 2
      ;;
    -a|--agent-port)
      AGENT_PORT="$2"
      shift 2
      ;;
    -l|--logs-dir)
      LOGS_DIR="$2"
      shift 2
      ;;
    -u|--user)
      JENKINS_ADMIN_USER="$2"
      shift 2
      ;;
    -w|--password)
      JENKINS_ADMIN_PASSWORD="$2"
      shift 2
      ;;
    -k|--keep)
      KEEP_CONTAINER=true
      shift
      ;;
    -s|--skip-cleanup)
      SKIP_CLEANUP=true
      shift
      ;;
    -d|--debug)
      DEBUG_MODE=true
      shift
      ;;
    -h|--help)
      show_help
      ;;
    *)
      log_error "Unknown option: $1"
      show_help
      ;;
  esac
done

# Extract credentials from JCasC file if not provided as parameters
if [ "$JENKINS_ADMIN_USER" = "admin" ] && [ "$JENKINS_ADMIN_PASSWORD" = "admin123" ] && [ -f "$JCASC_FILE" ]; then
  log_info "Checking JCasC file for credentials..."
  
  # Try to extract username and password from JCasC file if they exist
  EXTRACTED_USER=$(grep -A 3 "id:" "$JCASC_FILE" | grep "id:" | head -1 | sed 's/.*id: *"\([^"]*\).*/\1/;s/.*id: *\([^"]*\).*/\1/' 2>/dev/null)
  EXTRACTED_PASS=$(grep -A 3 "password:" "$JCASC_FILE" | grep "password:" | head -1 | sed 's/.*password: *"\([^"]*\).*/\1/;s/.*password: *\([^"]*\).*/\1/' 2>/dev/null)
  
  if [ -n "$EXTRACTED_USER" ] && [ -n "$EXTRACTED_PASS" ]; then
    log_info "Using credentials from JCasC file"
    JENKINS_ADMIN_USER="$EXTRACTED_USER"
    JENKINS_ADMIN_PASSWORD="$EXTRACTED_PASS"
  else
    log_info "Could not extract credentials from JCasC file, using defaults"
  fi
fi

# Check if Docker is installed and running
if ! command -v docker &>/dev/null; then
  error_exit "Docker is not installed or not in PATH"
fi

if ! docker info &>/dev/null; then
  error_exit "Docker daemon is not running or you don't have permission to access it"
fi

# Check if files exist
if [ ! -f "$JENKINSFILE" ]; then
  error_exit "Jenkinsfile not found at $JENKINSFILE"
fi

# Create default plugins file if it doesn't exist
if [ ! -f "$PLUGINS_FILE" ]; then
  log_info "Creating default plugins.txt file"
  cat > "$PLUGINS_FILE" << EOL
workflow-aggregator:latest
pipeline-stage-view:latest
git:latest
blueocean:latest
configuration-as-code:latest
job-dsl:latest
matrix-auth:latest
credentials:latest
credentials-binding:latest
EOL
fi

# Create default JCasC file if it doesn't exist
if [ ! -f "$JCASC_FILE" ]; then
  log_info "Creating default jenkins.yaml file"
  cat > "$JCASC_FILE" << EOL
jenkins:
  systemMessage: "Jenkins configured automatically by JCasC"
  numExecutors: 2
  securityRealm:
    local:
      allowsSignup: false
      users:
        - id: "$JENKINS_ADMIN_USER"
          password: "$JENKINS_ADMIN_PASSWORD"
  authorizationStrategy:
    loggedInUsersCanDoAnything:
      allowAnonymousRead: false
  
security:
  queueItemAuthenticator:
    authenticators:
    - global:
        strategy: triggeringUsersAuthorizationStrategy
EOL
else
  log_info "Using existing JCasC file: $JCASC_FILE"
  
  # Check if we need to update username/password in the existing JCasC file
  if grep -q "securityRealm" "$JCASC_FILE"; then
    log_info "Security realm already defined in JCasC file"
  else
    log_info "Adding security realm to JCasC file"
    # Create a temporary file
    TEMP_JCASC=$(mktemp)
    cat "$JCASC_FILE" > "$TEMP_JCASC"
    
    # Append security configuration if not present
    cat >> "$TEMP_JCASC" << EOL

# Added security configuration
jenkins:
  securityRealm:
    local:
      allowsSignup: false
      users:
        - id: "$JENKINS_ADMIN_USER"
          password: "$JENKINS_ADMIN_PASSWORD"
  authorizationStrategy:
    loggedInUsersCanDoAnything:
      allowAnonymousRead: false
EOL
    # Replace original file with updated one
    cat "$TEMP_JCASC" > "$JCASC_FILE"
    rm "$TEMP_JCASC"
  fi
fi

# Create logs directory if it doesn't exist
mkdir -p "$LOGS_DIR"

# Log important information
log_info "Starting Jenkins Docker Runner"
log_info "Container name: $CONTAINER_NAME"
log_info "Job name: $JOB_NAME"
log_info "Jenkinsfile: $JENKINSFILE"
log_info "Jenkins port: $PORT"
log_info "Logs directory: $LOGS_DIR"
log_info "Admin user: $JENKINS_ADMIN_USER"

# Create Docker network if it doesn't exist
if ! docker network inspect "$DOCKER_NETWORK" &>/dev/null; then
  log_info "Creating Docker network: $DOCKER_NETWORK"
  docker network create "$DOCKER_NETWORK" || error_exit "Failed to create Docker network"
fi

# Create a temporary directory for build context
TEMP_DIR=$(mktemp -d)
log_debug "Created temporary directory: $TEMP_DIR"
trap 'rm -rf "$TEMP_DIR"' EXIT

# Create directory structure
mkdir -p "$TEMP_DIR/init.groovy.d"
mkdir -p "$TEMP_DIR/scripts"

# Create Dockerfile
cat > "$TEMP_DIR/Dockerfile" << EOL
FROM $JENKINS_IMAGE

# Skip setup wizard and set environment variables
ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false -Dhudson.model.DirectoryBrowserSupport.CSP="
ENV JENKINS_OPTS="--httpPort=8085 --sessionTimeout=1440"
ENV REF_DIR=/usr/share/jenkins/ref
ENV JENKINS_ADMIN_ID="$JENKINS_ADMIN_USER"
ENV JENKINS_ADMIN_PASSWORD="$JENKINS_ADMIN_PASSWORD"
ENV CASC_JENKINS_CONFIG=/var/jenkins_home/casc_configs
ENV CASC_RELOAD_TOKEN=RELOAD

# Create required directories
USER root
RUN mkdir -p /var/jenkins_home/casc_configs /var/jenkins_home/logs /var/jenkins_home/scripts
RUN chown -R jenkins:jenkins /var/jenkins_home

# Install plugins
COPY plugins.txt \${REF_DIR}/plugins.txt
RUN jenkins-plugin-cli --plugin-file \${REF_DIR}/plugins.txt

# Copy JCasC configuration
COPY jenkins.yaml /var/jenkins_home/casc_configs/jenkins.yaml

# Copy Jenkinsfile
COPY Jenkinsfile /var/jenkins_home/Jenkinsfile

# Copy init scripts and job runner
COPY init.groovy.d/ \${REF_DIR}/init.groovy.d/
COPY scripts/ /var/jenkins_home/scripts/

# Install required utilities
RUN apt-get update && apt-get install -y curl jq wait-for-it && apt-get clean
RUN chmod -R 755 /var/jenkins_home/scripts

# Make sure JCasC configuration is readable
RUN cat /var/jenkins_home/casc_configs/jenkins.yaml
RUN chmod 644 /var/jenkins_home/casc_configs/jenkins.yaml

# Back to jenkins user
USER jenkins
EOL

# Create security setup script - this provides a fallback if JCasC fails
cat > "$TEMP_DIR/init.groovy.d/00-security.groovy" << EOL
import jenkins.model.*
import hudson.security.*
import jenkins.install.*
import hudson.util.VersionNumber

def instance = Jenkins.getInstance()

// Skip the setup wizard
if(!instance.getSetupWizard().isComplete()) {
    println("Skipping setup wizard")
    instance.setInstallState(InstallState.INITIAL_SETUP_COMPLETED)
}

// Only set up security if not already configured via JCasC
def strategy = instance.getAuthorizationStrategy()
def realm = instance.getSecurityRealm()
boolean needsConfiguring = (!(strategy instanceof FullControlOnceLoggedInAuthorizationStrategy) &&
                           !(realm instanceof HudsonPrivateSecurityRealm))

if (needsConfiguring) {
    println("Setting up security from init script as fallback")
    
    def hudsonRealm = new HudsonPrivateSecurityRealm(false)
    hudsonRealm.createAccount("$JENKINS_ADMIN_USER", "$JENKINS_ADMIN_PASSWORD")
    instance.setSecurityRealm(hudsonRealm)
    
    def authStrategy = new FullControlOnceLoggedInAuthorizationStrategy()
    authStrategy.setAllowAnonymousRead(false)
    instance.setAuthorizationStrategy(authStrategy)
    
    instance.save()
    println("Security configuration complete from init script")
} else {
    println("Security already configured, likely via JCasC")
}
EOL

# Add auto-triggering functionality to the job creation script
cat > "$TEMP_DIR/init.groovy.d/01-create-job.groovy" << EOL
import jenkins.model.*
import hudson.model.*
import org.jenkinsci.plugins.workflow.job.WorkflowJob
import org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition
import hudson.triggers.SCMTrigger
import hudson.plugins.git.*
import com.cloudbees.hudson.plugins.folder.*

def jenkins = Jenkins.getInstance()

// Create a pipeline job from Jenkinsfile
def jobName = "$JOB_NAME"
def job = jenkins.getItem(jobName)

if (job == null) {
    println "Creating pipeline job: \${jobName}"
    job = jenkins.createProject(WorkflowJob.class, jobName)
    
    // Read Jenkinsfile content
    def jenkinsfileContent = new File("/var/jenkins_home/Jenkinsfile").text
    
    // Create pipeline definition
    def flowDefinition = new CpsFlowDefinition(jenkinsfileContent, true)
    job.setDefinition(flowDefinition)
    
    // Save job
    job.save()
    jenkins.save()
    
    // Mark job as created successfully
    new File("/var/jenkins_home/job-created").createNewFile()
    println "Job created successfully: \${jobName}"
} else {
    println "Job already exists: \${jobName}"
    
    // Update job definition
    def jenkinsfileContent = new File("/var/jenkins_home/Jenkinsfile").text
    def flowDefinition = new CpsFlowDefinition(jenkinsfileContent, true)
    job.setDefinition(flowDefinition)
    job.save()
    
    // Mark job as updated successfully
    new File("/var/jenkins_home/job-updated").createNewFile()
    println "Job updated: \${jobName}"
}

// Schedule a build to run automatically
try {
    println "Scheduling immediate build for job: \${jobName}"
    def cause = new Cause.UserIdCause(userId: "system")
    def queueItem = job.scheduleBuild2(0, cause)
    
    if (queueItem != null) {
        new File("/var/jenkins_home/build-triggered-by-groovy").createNewFile()
        println "Build scheduled successfully via Groovy"
    } else {
        println "Failed to schedule build via Groovy"
    }
} catch (Exception e) {
    println "Error scheduling build: \${e.message}"
    e.printStackTrace()
}
EOL

# Add diagnostic script to check JCasC loading
cat > "$TEMP_DIR/init.groovy.d/02-check-jcasc.groovy" << EOL
import jenkins.model.*
import io.jenkins.plugins.casc.*

def instance = Jenkins.getInstance()

// Try to check if JCasC is loaded/configured
try {
    def configurationAsCode = instance.getExtensionList(ConfigurationAsCode.class)[0]
    if (configurationAsCode) {
        def sources = configurationAsCode.getSources()
        println "JCasC configuration sources: \${sources}"
        
        def lastTimeLoaded = configurationAsCode.getLastTimeLoaded()
        if (lastTimeLoaded) {
            println "JCasC configuration last loaded at: \${lastTimeLoaded}"
        } else {
            println "JCasC has not loaded any configuration yet"
        }
    } else {
        println "JCasC extension not found"
    }
} catch (Exception e) {
    println "Error checking JCasC: \${e.message}"
    e.printStackTrace()
}

// Check if security is set up as expected
def realm = instance.getSecurityRealm()
def strategy = instance.getAuthorizationStrategy()

println "Current security realm: \${realm.getClass().getName()}"
println "Current authorization strategy: \${strategy.getClass().getName()}"

// Check for the user we expect
def user = hudson.model.User.getById("$JENKINS_ADMIN_USER", false)
if (user) {
    println "User '$JENKINS_ADMIN_USER' exists"
} else {
    println "WARNING: User '$JENKINS_ADMIN_USER' not found"
}
EOL

# Create initialization completion marker script
cat > "$TEMP_DIR/init.groovy.d/99-init-complete.groovy" << EOL
// Create a marker file to signal that all scripts have run
new File("/var/jenkins_home/init-scripts-complete").createNewFile()
println "All initialization scripts completed"
EOL

# Create a more reliable job trigger in run-job.sh
cat > "$TEMP_DIR/scripts/run-job.sh" << EOSH
#!/bin/bash
set -e

JOB_NAME="$JOB_NAME"
JENKINS_URL="http://localhost:8085"
MAX_WAIT_TIME=$MAX_WAIT_TIME
POLL_INTERVAL=$POLL_INTERVAL
LOG_DIR="/var/jenkins_home/logs"
JENKINS_USER="$JENKINS_ADMIN_USER"
JENKINS_PASSWORD="$JENKINS_ADMIN_PASSWORD"

# Create log directory
mkdir -p \$LOG_DIR

# Create a debug log file
> "\$LOG_DIR/api-debug.log"
echo "Creating API debug log at: \$LOG_DIR/api-debug.log"

# Wait for Jenkins to initialize
echo "Waiting for Jenkins to initialize..."
INIT_WAIT=0
while [ ! -f /var/jenkins_home/init-scripts-complete ] && [ \$INIT_WAIT -lt \$MAX_WAIT_TIME ]; do
  sleep \$POLL_INTERVAL
  INIT_WAIT=\$((INIT_WAIT + POLL_INTERVAL))
  echo "Waiting for Jenkins initialization... (\$INIT_WAIT seconds)"
done

if [ ! -f /var/jenkins_home/init-scripts-complete ]; then
  echo "ERROR: Jenkins failed to initialize within \$MAX_WAIT_TIME seconds"
  exit 1
fi

# Wait a bit more to ensure Jenkins is fully ready
sleep 5

# Verify the job exists
echo "Verifying job exists: \$JOB_NAME"
JOB_URL="\${JENKINS_URL}/job/\${JOB_NAME}"
JOB_STATUS=\$(curl -s -o /dev/null -w "%{http_code}" -u \$JENKINS_USER:\$JENKINS_PASSWORD "\$JOB_URL/api/json" 2>/dev/null || echo "404")

if [ "\$JOB_STATUS" != "200" ]; then
  echo "ERROR: Job '\$JOB_NAME' not found (HTTP \$JOB_STATUS)"
  # List available jobs to help troubleshoot
  echo "Available jobs:"
  curl -s -u \$JENKINS_USER:\$JENKINS_PASSWORD "\${JENKINS_URL}/api/json?tree=jobs[name]" | jq -r '.jobs[].name' 2>/dev/null || echo "Could not list jobs"
  exit 1
fi

echo "Job verified: \$JOB_NAME is available at \$JOB_URL"

# Function to get Jenkins crumb for CSRF protection
get_crumb() {
  local attempt=0
  local max_attempts=10
  local crumb=""
  
  while [ \$attempt -lt \$max_attempts ]; do
    crumb=\$(curl -s -u \$JENKINS_USER:\$JENKINS_PASSWORD "\${JENKINS_URL}/crumbIssuer/api/json" | jq -r '.crumb' 2>/dev/null)
    
    if [ -n "\$crumb" ] && [ "\$crumb" != "null" ]; then
      echo "\$crumb"
      return 0
    fi
    
    attempt=\$((attempt + 1))
    echo "Failed to get crumb, retrying (\$attempt/\$max_attempts)..."
    sleep 3
  done
  
  echo ""
  return 1
}

# Function to check if Blue Ocean API is available
check_blue_ocean() {
  if curl -s -u \$JENKINS_USER:\$JENKINS_PASSWORD "\${JENKINS_URL}/blue/rest/organizations/jenkins/pipelines/" &>/dev/null; then
    return 0
  else
    return 1
  fi
}

# Get Jenkins crumb
echo "Getting Jenkins crumb..."
CRUMB=\$(get_crumb)

if [ -z "\$CRUMB" ]; then
  echo "ERROR: Failed to get Jenkins crumb after multiple attempts"
  exit 1
fi

# Check if Blue Ocean is available
if check_blue_ocean; then
  echo "Blue Ocean API is available"
  USE_BLUE_OCEAN=true
else
  echo "Blue Ocean API is not available, using standard Jenkins API"
  USE_BLUE_OCEAN=false
fi

# Modify run-job.sh to focus on finding builds rather than triggering
cat >> "$TEMP_DIR/scripts/run-job.sh" << EOSH

# Fetching current build information before continuing
echo "Looking for builds that have been triggered..."
BUILDS_INFO=\$(curl -s -u \$JENKINS_USER:\$JENKINS_PASSWORD "\${JOB_URL}/api/json?tree=builds[number,timestamp,building]" 2>/dev/null)
echo "Found build info: \$BUILDS_INFO" >> "\$LOG_DIR/api-debug.log"

# Check if we have any builds
HAVE_BUILDS=\$(echo "\$BUILDS_INFO" | jq -r '.builds | length' 2>/dev/null)

if [ "\$HAVE_BUILDS" = "0" ] || [ -z "\$HAVE_BUILDS" ]; then
  echo "No builds found. Attempting to force trigger a build..."
  
  # Try to trigger a build since none exist
  echo "Triggering job: \${JOB_NAME}"
  BUILD_TRIGGER=\$(curl -s -X POST -u \$JENKINS_USER:\$JENKINS_PASSWORD -H "Jenkins-Crumb: \${CRUMB}" "\${JOB_URL}/build")
  
  # Wait a moment for build to start
  sleep 5
  
  # Retry fetching builds
  BUILDS_INFO=\$(curl -s -u \$JENKINS_USER:\$JENKINS_PASSWORD "\${JOB_URL}/api/json?tree=builds[number,timestamp,building]" 2>/dev/null)
  HAVE_BUILDS=\$(echo "\$BUILDS_INFO" | jq -r '.builds | length' 2>/dev/null)
  
  if [ "\$HAVE_BUILDS" = "0" ] || [ -z "\$HAVE_BUILDS" ]; then
    echo "ERROR: Failed to find or trigger any builds for job \$JOB_NAME"
    exit 1
  fi
fi

# Find the most recent build
BUILD_NUMBER=\$(echo "\$BUILDS_INFO" | jq -r '.builds[0].number' 2>/dev/null)

if [ -z "\$BUILD_NUMBER" ] || [ "\$BUILD_NUMBER" = "null" ]; then
  echo "ERROR: Could not determine build number"
  exit 1
fi

echo "Found build #\$BUILD_NUMBER, will track this build"
EOSH

# First, try to get queue item URL
while [ -z "\$QUEUE_ITEM_URL" ] && [ \$BUILD_WAIT -lt 60 ]; do
  echo "Fetching queue information..."
  QUEUE_ITEMS=\$(curl -s -u \$JENKINS_USER:\$JENKINS_PASSWORD "\${JENKINS_URL}/queue/api/json?pretty=true")
  echo "Queue items: \$QUEUE_ITEMS" >> "\$LOG_DIR/api-debug.log"
  
  # Try to extract queue item for our job
  QUEUE_ITEM_URL=\$(echo "\$QUEUE_ITEMS" | jq -r '.items[] | select(.task.name=="'"$JOB_NAME"'") | .url' 2>/dev/null | head -n 1)
  
  if [ -n "\$QUEUE_ITEM_URL" ]; then
    echo "Job is in queue: \$QUEUE_ITEM_URL"
    break
  fi
  
  # Alternative approach: check if a new build already started
  BUILDS_INFO=\$(curl -s -u \$JENKINS_USER:\$JENKINS_PASSWORD "\${JOB_URL}/api/json?tree=builds[number,timestamp]" 2>/dev/null)
  echo "Build info: \$BUILDS_INFO" >> "\$LOG_DIR/api-debug.log"
  
  # Find builds started after we triggered
  if [ -n "\$BUILDS_INFO" ]; then
    # Try to find a build with timestamp after our trigger time (in milliseconds)
    PRE_TRIGGER_MS=\$((PRE_TRIGGER_TIME * 1000))
    NEW_BUILD_NUMBER=\$(echo "\$BUILDS_INFO" | jq -r ".builds[] | select(.timestamp > \$PRE_TRIGGER_MS) | .number" 2>/dev/null | head -n 1)
    
    if [ -n "\$NEW_BUILD_NUMBER" ] && [ "\$NEW_BUILD_NUMBER" != "null" ]; then
      BUILD_NUMBER=\$NEW_BUILD_NUMBER
      echo "Detected new build #\$BUILD_NUMBER by timestamp"
      break
    fi
    
    # Alternatively, check if there's a newer build number than the last one we saw
    NEW_BUILD_NUMBER=\$(echo "\$BUILDS_INFO" | jq -r ".builds[] | select(.number > \$LAST_BUILD_NUMBER) | .number" 2>/dev/null | head -n 1)
    
    if [ -n "\$NEW_BUILD_NUMBER" ] && [ "\$NEW_BUILD_NUMBER" != "null" ]; then
      BUILD_NUMBER=\$NEW_BUILD_NUMBER
      echo "Detected new build #\$BUILD_NUMBER by number comparison"
      break
    fi
  fi
  
  sleep \$POLL_INTERVAL
  BUILD_WAIT=\$((BUILD_WAIT + POLL_INTERVAL))
  echo "Waiting for job to enter queue or start building... (\$BUILD_WAIT seconds)"
done

# Now wait for queue item to convert to a build
if [ -n "\$QUEUE_ITEM_URL" ]; then
  echo "Waiting for queued job to start building..."
  QUEUE_WAIT=0
  
  while [ -z "\$BUILD_NUMBER" ] && [ \$QUEUE_WAIT -lt 60 ]; do
    # Check if queue item has executable (build)
    QUEUE_ITEM=\$(curl -s -u \$JENKINS_USER:\$JENKINS_PASSWORD "\$QUEUE_ITEM_URL/api/json")
    EXECUTABLE=\$(echo "\$QUEUE_ITEM" | jq -r '.executable.url // ""' 2>/dev/null)
    
    if [ -n "\$EXECUTABLE" ]; then
      BUILD_NUMBER=\$(echo "\$QUEUE_ITEM" | jq -r '.executable.number' 2>/dev/null)
      echo "Build #\$BUILD_NUMBER started from queue"
      break
    fi
    
    sleep \$POLL_INTERVAL
    QUEUE_WAIT=\$((QUEUE_WAIT + POLL_INTERVAL))
    echo "Waiting for queued job to start... (\$QUEUE_WAIT seconds)"
  done
fi

# If we couldn't track via queue, check for new builds
if [ -z "\$BUILD_NUMBER" ]; then
  echo "Checking build history to find our triggered build..."
  
  # Try multiple approaches to find the build
  for attempt in {1..5}; do
    echo "Attempt $attempt to find build number..."
    
    # Approach 1: Look at all builds and find most recent one
    BUILDS_INFO=\$(curl -s -u \$JENKINS_USER:\$JENKINS_PASSWORD "\${JOB_URL}/api/json?tree=builds[number,timestamp,building]" 2>/dev/null)
    
    # First look for currently building jobs
    BUILDING_BUILD=\$(echo "\$BUILDS_INFO" | jq -r '.builds[] | select(.building==true) | .number' 2>/dev/null | head -n 1)
    if [ -n "\$BUILDING_BUILD" ] && [ "\$BUILDING_BUILD" != "null" ]; then
      BUILD_NUMBER=\$BUILDING_BUILD
      echo "Found currently building job #\$BUILD_NUMBER"
      break
    fi
    
    # If no building job, get newest build that is newer than our last known build
    NEWEST_BUILD=\$(echo "\$BUILDS_INFO" | jq -r ".builds[] | select(.number > \$LAST_BUILD_NUMBER) | .number" 2>/dev/null | sort -nr | head -n 1)
    if [ -n "\$NEWEST_BUILD" ] && [ "\$NEWEST_BUILD" != "null" ]; then
      BUILD_NUMBER=\$NEWEST_BUILD
      echo "Found newest build #\$BUILD_NUMBER (newer than #\$LAST_BUILD_NUMBER)"
      break
    fi
    
    # Approach 2: Use the lastBuild field directly
    LAST_BUILD_INFO=\$(curl -s -u \$JENKINS_USER:\$JENKINS_PASSWORD "\${JOB_URL}/api/json?tree=lastBuild[number,timestamp]" 2>/dev/null)
    CURRENT_LAST_BUILD=\$(echo "\$LAST_BUILD_INFO" | jq -r '.lastBuild.number // 0' 2>/dev/null)
    
    if [ "\$CURRENT_LAST_BUILD" != "null" ] && [ "\$CURRENT_LAST_BUILD" -gt "\$LAST_BUILD_NUMBER" ]; then
      BUILD_NUMBER=\$CURRENT_LAST_BUILD
      echo "Found last build #\$BUILD_NUMBER (using lastBuild field)"
      break
    fi
    
    # Approach 3: Directly check build numbers sequentially
    potential_build=\$(( LAST_BUILD_NUMBER + 1 ))
    BUILD_CHECK_URL="\${JOB_URL}/\${potential_build}/api/json"
    BUILD_EXISTS=\$(curl -s -I -u \$JENKINS_USER:\$JENKINS_PASSWORD "\$BUILD_CHECK_URL" | grep -c "200 OK" || echo "0")
    
    if [ "\$BUILD_EXISTS" -gt 0 ]; then
      BUILD_NUMBER=\$potential_build
      echo "Found build #\$BUILD_NUMBER by direct check"
      break
    fi
    
    sleep 3
  done
fi

# Final fallback: try triggering the job again
if [ -z "\$BUILD_NUMBER" ]; then
  echo "Could not detect build number. Trying to trigger the job again..."
  TRIGGER_AGAIN=\$(curl -s -X POST -u \$JENKINS_USER:\$JENKINS_PASSWORD -H "Jenkins-Crumb: \${CRUMB}" "\${JOB_URL}/build")
  
  sleep 5
  
  # Check once more for the latest build
  LAST_BUILD_INFO=\$(curl -s -u \$JENKINS_USER:\$JENKINS_PASSWORD "\${JOB_URL}/api/json?tree=lastBuild[number]" 2>/dev/null)
  CURRENT_LAST_BUILD=\$(echo "\$LAST_BUILD_INFO" | jq -r '.lastBuild.number // 0' 2>/dev/null)
  
  if [ "\$CURRENT_LAST_BUILD" != "null" ] && [ "\$CURRENT_LAST_BUILD" -gt 0 ]; then
    BUILD_NUMBER=\$CURRENT_LAST_BUILD
    echo "Using latest build #\$BUILD_NUMBER after re-triggering"
  else
    echo "ERROR: Could not determine build number. Jenkins may not be functioning correctly."
    echo "Check Jenkins UI at: \${JENKINS_URL}"
    exit 1
  fi
fi

# Save build information
echo "Detected build #\$BUILD_NUMBER - saving information..."
echo "\$BUILD_NUMBER" > "\$LOG_DIR/build-number"
echo "\$JOB_NAME" > "\$LOG_DIR/job-name"

# Verify the build exists before proceeding
echo "Verifying build #\$BUILD_NUMBER exists..."
BUILD_CHECK_URL="\${JOB_URL}/\${BUILD_NUMBER}/api/json"
for i in {1..5}; do
  BUILD_EXISTS=\$(curl -s -I -u \$JENKINS_USER:\$JENKINS_PASSWORD "\$BUILD_CHECK_URL" | grep -c "200 OK" || echo "0")
  
  if [ "\$BUILD_EXISTS" -gt 0 ]; then
    echo "Build #\$BUILD_NUMBER confirmed to exist"
    break
  fi
  
  if [ \$i -eq 5 ]; then
    echo "WARNING: Could not confirm build #\$BUILD_NUMBER exists, but will try to proceed"
  else
    echo "Waiting for build #\$BUILD_NUMBER to become available (attempt \$i)..."
    sleep 3
  fi
done

# Output build URL for reference
echo "Build URL: \${JOB_URL}/\${BUILD_NUMBER}/"
echo "Blue Ocean URL: \${JENKINS_URL}/blue/organizations/jenkins/\${JOB_NAME}/detail/\${JOB_NAME}/\${BUILD_NUMBER}/"

# Function to get build status from standard Jenkins API
get_build_status() {
  local build_num=\$1
  local build_url="\${JOB_URL}/\${build_num}/api/json"
  
  # First check if the build exists
  local build_exists=\$(curl -s -I -u \$JENKINS_USER:\$JENKINS_PASSWORD "\$build_url" | grep -c "200 OK" || echo "0")
  
  if [ "\$build_exists" -eq 0 ]; then
    echo "{\\"building\\":false,\\"result\\":\\"NOT_FOUND\\"}"
    return
  fi
  
  local build_info=\$(curl -s -u \$JENKINS_USER:\$JENKINS_PASSWORD "\$build_url" 2>/dev/null)
  local building=\$(echo "\$build_info" | jq -r '.building // null' 2>/dev/null)
  local result=\$(echo "\$build_info" | jq -r '.result // null' 2>/dev/null)
  
  # For debugging
  echo "Build status API response: \$build_info" >> "\$LOG_DIR/api-debug.log"
  
  # Handle null values
  if [ "\$building" = "null" ] || [ -z "\$building" ]; then
    building=false
  fi
  
  # Special case: if result is null but building is false, the build might be finalizing
  if [ "\$building" = "false" ] && [ "\$result" = "null" ]; then
    result="FINALIZING"
  fi
  
  echo "{\\"building\\":\${building},\\"result\\":\\"\${result}\\"}"
}

# Function to get build status from Blue Ocean API
get_blue_ocean_status() {
  local build_num=\$1
  local blue_url="\${JENKINS_URL}/blue/rest/organizations/jenkins/pipelines/\${JOB_NAME}/runs/\${build_num}/"
  
  # First check if the build exists in Blue Ocean API
  local blue_exists=\$(curl -s -I -u \$JENKINS_USER:\$JENKINS_PASSWORD "\$blue_url" | grep -c "200 OK" || echo "0")
  
  if [ "\$blue_exists" -eq 0 ]; then
    echo "{\\"building\\":false,\\"result\\":\\"NOT_FOUND\\"}"
    return
  fi
  
  local blue_info=\$(curl -s -u \$JENKINS_USER:\$JENKINS_PASSWORD "\$blue_url" 2>/dev/null)
  local blue_status=\$(echo "\$blue_info" | jq -r '.state // null' 2>/dev/null)
  local blue_result=\$(echo "\$blue_info" | jq -r '.result // null' 2>/dev/null)
  
  # For debugging
  echo "Blue Ocean API response: \$blue_info" >> "\$LOG_DIR/api-debug.log"
  
  # Map Blue Ocean status to Jenkins status format
  local building=false
  if [ "\$blue_status" = "RUNNING" ] || [ "\$blue_status" = "QUEUED" ]; then
    building=true
  fi
  
  # If Blue Ocean knows the build but has no result, it's probably still initializing
  if [ "\$blue_result" = "null" ] && [ "\$blue_status" != "RUNNING" ] && [ "\$blue_status" != "QUEUED" ]; then
    blue_result="INITIALIZING"
  fi
  
  echo "{\\"building\\":\${building},\\"result\\":\\"\${blue_result}\\"}"
}

# Stream the console output
echo "=== Streaming build #\${BUILD_NUMBER} console output ==="
BUILD_URL="\${JOB_URL}/\${BUILD_NUMBER}"
CONSOLE_URL="\${BUILD_URL}/logText/progressiveText"
LOG_FILE="\$LOG_DIR/\${JOB_NAME}-\${BUILD_NUMBER}.log"

# Initialize log file
> "\$LOG_FILE"

COMPLETED=false
OFFSET=0
BUILD_DURATION=0
NO_PROGRESS_COUNT=0

while [ "\${COMPLETED}" = "false" ] && [ \$BUILD_DURATION -lt \$MAX_WAIT_TIME ]; do
  # Get console output
  RESPONSE=\$(curl -s -u \$JENKINS_USER:\$JENKINS_PASSWORD "\${CONSOLE_URL}?start=\${OFFSET}")
  CONSOLE_OUTPUT=\$(echo "\${RESPONSE}" | sed \s/\\r\\n/\\n/g')
  
  if [ -n "\${CONSOLE_OUTPUT}" ]; then
    echo -n "\${CONSOLE_OUTPUT}" | tee -a "\$LOG_FILE"
    OFFSET=\$((OFFSET + \${#CONSOLE_OUTPUT}))
    NO_PROGRESS_COUNT=0
  else
    NO_PROGRESS_COUNT=\$((NO_PROGRESS_COUNT + 1))
    
    # If no output for a while, try different console URL formats
    if [ \$NO_PROGRESS_COUNT -gt 5 ]; then
      echo "No console output for a while, trying alternative URLs..."
      
      # Try Blue Ocean console URL
      if [ "\$USE_BLUE_OCEAN" = true ]; then
        BLUE_LOGS=\$(curl -s -u \$JENKINS_USER:\$JENKINS_PASSWORD "\${JENKINS_URL}/blue/rest/organizations/jenkins/pipelines/\${JOB_NAME}/runs/\${BUILD_NUMBER}/log/" 2>/dev/null)
        if [ -n "\$BLUE_LOGS" ]; then
          echo -n "\$BLUE_LOGS" | tee -a "\$LOG_FILE"
          echo "Retrieved logs from Blue Ocean API" | tee -a "\$LOG_FILE"
        fi
      fi
      
      # Reset counter so we don't spam these requests
      NO_PROGRESS_COUNT=0
    fi
  fi
  
  # Check if build is complete
  if [ "\$USE_BLUE_OCEAN" = true ]; then
    BUILD_STATUS_JSON=\$(get_blue_ocean_status "\$BUILD_NUMBER")
  else
    BUILD_STATUS_JSON=\$(get_build_status "\$BUILD_NUMBER")
  fi
  
  # Echo status for debugging
  echo "Current status: \$BUILD_STATUS_JSON" >> "\$LOG_DIR/api-debug.log"
  
  # Extract values from JSON
  BUILDING=\$(echo "\$BUILD_STATUS_JSON" | jq -r '.building')
  BUILD_RESULT=\$(echo "\$BUILD_STATUS_JSON" | jq -r '.result')
  
  # Special handling for builds that can't be found
  if [ "\$BUILD_RESULT" = "NOT_FOUND" ]; then
    echo "WARNING: Build #\$BUILD_NUMBER not found via API. Rechecking..."
    sleep 5
    continue
  fi
  
  # Check for completion
  if [ "\${BUILDING}" = "false" ] && [ "\${BUILD_RESULT}" != "null" ] && [ "\${BUILD_RESULT}" != "FINALIZING" ] && [ "\${BUILD_RESULT}" != "INITIALIZING" ]; then
    COMPLETED=true
    echo -e "\n\nBuild completed with status: \${BUILD_RESULT}"
  else
    if [ "\${BUILD_RESULT}" = "FINALIZING" ] || [ "\${BUILD_RESULT}" = "INITIALIZING" ]; then
      echo "Build is in state: \${BUILD_RESULT}, waiting for final status..."
    fi
    sleep \$POLL_INTERVAL
    BUILD_DURATION=\$((BUILD_DURATION + POLL_INTERVAL))
  fi
done

echo -e "\n=== End of console output ===\n"

if [ "\${COMPLETED}" = "false" ]; then
  echo "ERROR: Build did not complete within \$MAX_WAIT_TIME seconds" | tee -a "\$LOG_FILE"
  exit 1
fi

# Save build result
echo "\${BUILD_RESULT}" > "\$LOG_DIR/build-result"

# Save build details to JSON
echo "Saving build details..."
curl -s -u \$JENKINS_USER:\$JENKINS_PASSWORD "\${BUILD_URL}/api/json" > "\$LOG_DIR/\${JOB_NAME}-\${BUILD_NUMBER}-details.json"

# Save Blue Ocean details if available
if [ "\$USE_BLUE_OCEAN" = true ]; then
  curl -s -u \$JENKINS_USER:\$JENKINS_PASSWORD "\${JENKINS_URL}/blue/rest/organizations/jenkins/pipelines/\${JOB_NAME}/runs/\${BUILD_NUMBER}/" > "\$LOG_DIR/\${JOB_NAME}-\${BUILD_NUMBER}-blue-ocean.json"
fi

# Try to download artifacts if any exist
ARTIFACTS_JSON=\$(curl -s -u \$JENKINS_USER:\$JENKINS_PASSWORD "\${BUILD_URL}/api/json?tree=artifacts[*]")
ARTIFACTS=\$(echo "\${ARTIFACTS_JSON}" | jq -r '.artifacts[] | .relativePath' 2>/dev/null)

if [ -n "\${ARTIFACTS}" ] && [ "\${ARTIFACTS}" != "null" ]; then
  ARTIFACTS_DIR="\$LOG_DIR/artifacts"
  mkdir -p "\${ARTIFACTS_DIR}"
  
  echo "Downloading artifacts..."
  for ARTIFACT in \${ARTIFACTS}; do
    echo "  - \${ARTIFACT}"
    ARTIFACT_URL="\${BUILD_URL}/artifact/\${ARTIFACT}"
    ARTIFACT_DIR="\${ARTIFACTS_DIR}/\$(dirname "\${ARTIFACT}")"
    mkdir -p "\${ARTIFACT_DIR}"
    curl -s -u \$JENKINS_USER:\$JENKINS_PASSWORD "\${ARTIFACT_URL}" -o "\${ARTIFACTS_DIR}/\${ARTIFACT}"
  done
fi

# Print final summary
echo -e "\n=== Build Summary ==="
echo "Job Name: \$JOB_NAME"
echo "Build Number: \$BUILD_NUMBER"
echo "Result: \$BUILD_RESULT"
echo "Build URL: \$BUILD_URL"
echo "Log File: \$LOG_FILE"
if [ -n "\${ARTIFACTS}" ] && [ "\${ARTIFACTS}" != "null" ]; then
  echo "Artifacts: \$ARTIFACTS_DIR"
fi
echo "===================="

# Exit with appropriate code
if [ "\${BUILD_RESULT}" = "SUCCESS" ]; then
  exit 0
else
  exit 1
fi
EOSH

# Make script executable
chmod 755 "$TEMP_DIR/scripts/run-job.sh"

# Process input files
log_info "Processing input files"

# Copy Jenkinsfile
cp "$JENKINSFILE" "$TEMP_DIR/"
log_info "Copied Jenkinsfile"

# Process plugins file
cp "$PLUGINS_FILE" "$TEMP_DIR/"
log_info "Copied plugins file"

# Check if configuration-as-code plugin is in the plugins list
if ! grep -q "configuration-as-code" "$TEMP_DIR/plugins.txt"; then
  log_info "Adding configuration-as-code plugin"
  echo "configuration-as-code:latest" >> "$TEMP_DIR/plugins.txt"
fi

# Ensure necessary plugins are included
if ! grep -q "workflow-job" "$TEMP_DIR/plugins.txt"; then
  log_info "Adding workflow-job plugin"
  echo "workflow-job:latest" >> "$TEMP_DIR/plugins.txt"
fi
if ! grep -q "workflow-api" "$TEMP_DIR/plugins.txt"; then
  log_info "Adding workflow-api plugin"
  echo "workflow-api:latest" >> "$TEMP_DIR/plugins.txt"
fi
if ! grep -q "blueocean" "$TEMP_DIR/plugins.txt"; then
  log_info "Adding blueocean plugin"
  echo "blueocean:latest" >> "$TEMP_DIR/plugins.txt"
fi
if ! grep -q "matrix-auth" "$TEMP_DIR/plugins.txt"; then
  log_info "Adding matrix-auth plugin"
  echo "matrix-auth:latest" >> "$TEMP_DIR/plugins.txt"
fi

# Sort and remove duplicates from plugins list
sort -u "$TEMP_DIR/plugins.txt" -o "$TEMP_DIR/plugins.txt"

# Process JCasC file
cp "$JCASC_FILE" "$TEMP_DIR/jenkins.yaml"
log_info "Copied JCasC configuration file"

# Build custom Jenkins image
CUSTOM_IMAGE="custom-jenkins-${CONTAINER_NAME}:latest"
log_info "Building custom Jenkins image..."
docker build -t "$CUSTOM_IMAGE" "$TEMP_DIR" || error_exit "Failed to build Docker image"

# Clean up existing resources if not in debug mode
if [ "$DEBUG_MODE" = false ]; then
  cleanup
fi

# Create a dedicated volume for this run
docker volume create "${CONTAINER_NAME}_data" >/dev/null || error_exit "Failed to create Docker volume"

# Start Jenkins container with environment variables for JCasC
log_info "Starting Jenkins container with JCasC configuration..."
docker run --name "$CONTAINER_NAME" \
  --network "$DOCKER_NETWORK" \
  -p "$PORT:8080" \
  -p "$AGENT_PORT:50000" \
  -v "${CONTAINER_NAME}_data:$JENKINS_HOME" \
  -e "JENKINS_ADMIN_ID=$JENKINS_ADMIN_USER" \
  -e "JENKINS_ADMIN_PASSWORD=$JENKINS_ADMIN_PASSWORD" \
  -e "CASC_JENKINS_CONFIG=/var/jenkins_home/casc_configs" \
  -e "JENKINS_OPTS=--httpPort=8085" \
  -d "$CUSTOM_IMAGE" || error_exit "Failed to start Jenkins container"

# Check if container started successfully
if ! docker ps | grep -q "$CONTAINER_NAME"; then
  error_exit "Jenkins container failed to start"
fi

log_info "Jenkins container started with ID: $(docker ps -q -f name=$CONTAINER_NAME)"

# Wait for Jenkins to start
log_info "Waiting for Jenkins to start up..."
MAX_WAIT_FOR_JENKINS=120
JENKINS_WAIT=0

while [ $JENKINS_WAIT -lt $MAX_WAIT_FOR_JENKINS ]; do
  # Check if container is still running
  if ! docker ps | grep -q "$CONTAINER_NAME"; then
    error_exit "Jenkins container stopped unexpectedly"
  fi
  
  # Check if Jenkins is responding to HTTP requests
  HTTP_RESPONSE=$(docker exec "$CONTAINER_NAME" curl -s -o /dev/null -w "%{http_code}" http://localhost:8085 || echo "0")
  
  if [ "$HTTP_RESPONSE" == "200" ] || [ "$HTTP_RESPONSE" == "403" ]; then
    log_info "Jenkins is responding to HTTP requests"
    break
  fi
  
  sleep 5
  JENKINS_WAIT=$((JENKINS_WAIT + 5))
  log_info "Waiting for Jenkins to become available... ($JENKINS_WAIT seconds)"
done

if [ $JENKINS_WAIT -ge $MAX_WAIT_FOR_JENKINS ]; then
  log_debug "Jenkins failed to start. Container logs:"
  docker logs "$CONTAINER_NAME"
  error_exit "Jenkins failed to start within $MAX_WAIT_FOR_JENKINS seconds"
fi

# Wait for job creation and build triggering
log_info "Waiting for pipeline job to be created and triggered..."
JOB_CREATION_WAIT=0
JOB_CREATION_TIMEOUT=60

while [ $JOB_CREATION_WAIT -lt $JOB_CREATION_TIMEOUT ]; do
  if docker exec "$CONTAINER_NAME" [ -f "/var/jenkins_home/build-triggered-by-groovy" ]; then
    log_info "Jenkins job '$JOB_NAME' has been created and build triggered by Groovy script"
    break
  elif docker exec "$CONTAINER_NAME" [ -f "/var/jenkins_home/job-created" ] || docker exec "$CONTAINER_NAME" [ -f "/var/jenkins_home/job-updated" ]; then
    log_info "Jenkins job '$JOB_NAME' is ready, but build may not have been triggered automatically"
    # We'll trigger it manually later
    break
  fi
  
  sleep 2
  JOB_CREATION_WAIT=$((JOB_CREATION_WAIT + 2))
  log_info "Waiting for job creation... ($JOB_CREATION_WAIT seconds)"
done

if [ $JOB_CREATION_WAIT -ge $JOB_CREATION_TIMEOUT ]; then
  log_warn "Could not confirm job creation, but will attempt to continue"
fi

# Execute the job running script
log_info "Automatically triggering Jenkins pipeline for Jenkinsfile..."
JOB_EXIT_CODE=0

# Start tailing Jenkins logs in background
docker logs -f "$CONTAINER_NAME" > "$LOGS_DIR/jenkins-server.log" 2>&1 &
JENKINS_LOGS_PID=$!

# First try the direct trigger script (this is most reliable)
log_info "Triggering job using direct script approach..."
docker exec "$CONTAINER_NAME" bash /var/jenkins_home/scripts/direct-trigger.sh || true

# Wait a moment for the direct trigger to work
sleep 5

# Then try the explicit triggering script as fallback
if ! docker exec "$CONTAINER_NAME" [ -f "/var/jenkins_home/build-triggered-by-groovy" ]; then
  log_info "Groovy triggering not detected, using HTTP trigger approach..."
  docker exec "$CONTAINER_NAME" bash /tmp/trigger-job.sh || true
  # Wait a moment for HTTP trigger to work
  sleep 5
fi

# Then run the main job executor which will detect the build
log_info "Running pipeline executor to track the build..."
ATTEMPTS=0
MAX_ATTEMPTS=3

while [ $ATTEMPTS -lt $MAX_ATTEMPTS ]; do
  # The run-job.sh script should now find the triggered build rather than triggering a new one
  docker exec "$CONTAINER_NAME" bash /var/jenkins_home/scripts/run-job.sh && break
  JOB_EXIT_CODE=$?
  
  ATTEMPTS=$((ATTEMPTS + 1))
  if [ $ATTEMPTS -lt $MAX_ATTEMPTS ]; then
    log_warn "Job execution failed, retrying (attempt $ATTEMPTS of $MAX_ATTEMPTS)..."
    sleep 5
  else
    log_error "Failed to execute pipeline after $MAX_ATTEMPTS attempts"
  fi
done

# Stop tailing Jenkins logs
if [ -n "$JENKINS_LOGS_PID" ]; then
  kill $JENKINS_LOGS_PID 2>/dev/null || true
fi

# Copy logs from container to host
log_info "Copying job logs from container to host..."
docker cp "$CONTAINER_NAME:/var/jenkins_home/logs/." "$LOGS_DIR/"

# Process logs and determine build result
BUILD_NUMBER=""
JOB_NAME_FROM_FILE=""
BUILD_RESULT=""

# Get the build number from the saved file
if [ -f "$LOGS_DIR/build-number" ]; then
    BUILD_NUMBER=$(cat "$LOGS_DIR/build-number")
    log_info "Build number: $BUILD_NUMBER"
else
    log_warn "build-number file not found"
fi

# Get the job name from the saved file
if [ -f "$LOGS_DIR/job-name" ]; then
    JOB_NAME_FROM_FILE=$(cat "$LOGS_DIR/job-name")
    log_info "Job name: $JOB_NAME_FROM_FILE"
else
    log_warn "job-name file not found, using configured job name: $JOB_NAME"
    JOB_NAME_FROM_FILE="$JOB_NAME"
fi

# Get the build result from saved file
if [ -f "$LOGS_DIR/build-result" ]; then
    BUILD_RESULT=$(cat "$LOGS_DIR/build-result")
    log_info "Build result: $BUILD_RESULT"
else
    log_warn "build-result file not found, using job exit code"
    if [ $JOB_EXIT_CODE -eq 0 ]; then
        BUILD_RESULT="SUCCESS"
    else
        BUILD_RESULT="FAILURE"
    fi
fi

# Find the log file
if [ -n "$BUILD_NUMBER" ] && [ -n "$JOB_NAME_FROM_FILE" ]; then
    JOB_LOG="$LOGS_DIR/${JOB_NAME_FROM_FILE}-${BUILD_NUMBER}.log"
    
    if [ -f "$JOB_LOG" ]; then
        log_info "Job log found: $JOB_LOG"
    else
        log_warn "Expected log file not found: $JOB_LOG"
        # Fallback to searching for any log file
        JOB_LOG=$(find "$LOGS_DIR" -name "*.log" | grep -v "jenkins-server.log" | sort -r | head -n 1)
        if [ -n "$JOB_LOG" ]; then
            log_info "Using fallback log file: $JOB_LOG"
        else
            log_warn "No job log files found in $LOGS_DIR"
        fi
    fi
else
    log_warn "Build number or job name information missing, searching for log files..."
    JOB_LOG=$(find "$LOGS_DIR" -name "*.log" | grep -v "jenkins-server.log" | sort -r | head -n 1)
    if [ -n "$JOB_LOG" ]; then
        log_info "Found log file: $JOB_LOG"
    else
        log_warn "No job log files found in $LOGS_DIR"
    fi
fi

# Check for real-time log file first
REALTIME_LOG="$LOGS_DIR/${JOB_NAME_FROM_FILE}-${BUILD_NUMBER}-realtime.log"

# Check for artifacts
ARTIFACTS_DIR="$LOGS_DIR/artifacts"
if [ -d "$ARTIFACTS_DIR" ]; then
    log_info "Artifacts downloaded to: $ARTIFACTS_DIR"
    ls -la "$ARTIFACTS_DIR" || log_warn "Could not list artifacts directory"
fi

# Print final summary
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}Jenkins Pipeline Execution Summary${NC}"
echo -e "${GREEN}============================================================${NC}"
echo "Job Name: $JOB_NAME_FROM_FILE"
echo "Build Number: $BUILD_NUMBER"
echo "Result: $BUILD_RESULT"
echo "Log File: $JOB_LOG"
if [ -d "$ARTIFACTS_DIR" ]; then
    echo "Artifacts: $ARTIFACTS_DIR"
fi
echo -e "${GREEN}============================================================${NC}"

# Display log content if found
if [ -f "$REALTIME_LOG" ] && [ -s "$REALTIME_LOG" ]; then
    echo ""
    echo -e "${YELLOW}=== JOB LOG CONTENT (Real-time) ===${NC}"
    cat "$REALTIME_LOG"
    echo -e "${YELLOW}==================================${NC}"
elif [ -n "$JOB_LOG" ] && [ -f "$JOB_LOG" ]; then
    echo ""
    echo -e "${YELLOW}=== JOB LOG CONTENT ===${NC}"
    cat "$JOB_LOG"
    echo -e "${YELLOW}======================${NC}"
else
    log_warn "No job log content to display"
fi

# Ask user if they want to keep the container running
if [ "$KEEP_CONTAINER" = false ]; then
    echo ""
    echo "Do you want to keep the Jenkins container running? (yes/no)"
    echo "  - Enter 'yes' to keep the container"
    echo "  - Enter 'no' to stop and remove the container"
    read -r keep_response
    
    if [[ "$keep_response" =~ ^[Yy][Ee][Ss]$ ]]; then
        KEEP_CONTAINER=true
        log_info "Container will be kept running. You can access Jenkins at http://localhost:$PORT"
        log_info "Username: $JENKINS_ADMIN_USER"
        log_info "Password: $JENKINS_ADMIN_PASSWORD"
    else
        log_info "Container will be stopped and removed as requested"
    fi
fi

# Handle script exit
handle_exit $JOB_EXIT_CODE