#!/bin/bash
set -e

# Default values
JENKINS_HOME="/var/jenkins_home"
JENKINSFILE="Jenkinsfile"
PLUGINS_FILE="plugins.txt"
JCASC_FILE="jenkins.yaml"
SEEDJOB_FILE="seedJob.groovy"
JENKINS_IMAGE="jenkins/jenkins:lts"
DOCKER_NETWORK="jenkins-network"
CONTAINER_NAME="jenkins-runner"
PORT="8080"
AGENT_PORT="50000"

# Help function
function show_help {
  echo "Jenkins Docker Runner"
  echo "Usage: $0 [options]"
  echo ""
  echo "Options:"
  echo "  -f, --jenkinsfile FILE     Path to Jenkinsfile (default: ./Jenkinsfile)"
  echo "  -p, --plugins FILE         Path to plugins.txt file (default: ./plugins.txt)"
  echo "  -c, --casc FILE            Path to JCasC yaml file (default: ./jenkins.yaml)"
  echo "  -s, --seedjob FILE         Path to SEEDJOB.groovy file (default: ./seedJob.groovy)"
  echo "  -i, --image IMAGE          Jenkins Docker image (default: jenkins/jenkins:lts)"
  echo "  -n, --name NAME            Container name (default: jenkins-runner)"
  echo "  -P, --port PORT            Web UI port (default: 8080)"
  echo "  -a, --agent-port PORT      Agent port (default: 50000)"
  echo "  -v, --volume DIR           Mount a volume for Jenkins home (default: jenkins_home)"
  echo "  -d, --detach               Run container in detached mode"
  echo "  -h, --help                 Show this help message"
  exit 0
}

# Parse command line arguments
DETACH=""
VOLUME="jenkins_home"

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
    -s|--ssedjob)
      SEEDJOB_FILE="$2"
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
    -P|--port)
      PORT="$2"
      shift 2
      ;;
    -a|--agent-port)
      AGENT_PORT="$2"
      shift 2
      ;;
    -v|--volume)
      VOLUME="$2"
      shift 2
      ;;
    -d|--detach)
      DETACH="--detach"
      shift
      ;;
    -h|--help)
      show_help
      ;;
    *)
      echo "Unknown option: $1"
      show_help
      ;;
  esac
done

# Check if files exist
if [ ! -f "$JENKINSFILE" ]; then
  echo "Error: Jenkinsfile not found at $JENKINSFILE"
  exit 1
fi

if [ ! -f "$PLUGINS_FILE" ]; then
  echo "Error: Plugins file not found at $PLUGINS_FILE"
  exit 1
fi

if [ ! -f "$JCASC_FILE" ]; then
  echo "Error: JCasC file not found at $JCASC_FILE"
  exit 1
fi

if [ ! -f "$SEEDJOB_FILE"]; then
  echo "Error: SEEDJOB file not found at $SEEDJOB_FILE"
  exit 1
fi

# Create Docker network if it doesn't exist
if ! docker network inspect "$DOCKER_NETWORK" &>/dev/null; then
  echo "Creating Docker network: $DOCKER_NETWORK"
  docker network create "$DOCKER_NETWORK"
fi

# Create a temporary Dockerfile
TEMP_DIR=$(mktemp -d)
DOCKERFILE="$TEMP_DIR/Dockerfile"

cat > "$DOCKERFILE" << EOL
FROM $JENKINS_IMAGE

# Install plugins
COPY $PLUGINS_FILE /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

# Set up JCasC
ENV CASC_JENKINS_CONFIG /var/jenkins_home/casc_configs
RUN mkdir -p /var/jenkins_home/casc_configs
COPY $JCASC_FILE /var/jenkins_home/casc_configs/jenkins.yaml

# Copy Jenkinsfile
COPY $JENKINSFILE /var/jenkins_home/Jenkinsfile

# Skip initial setup wizard
ENV JAVA_OPTS -Djenkins.install.runSetupWizard=false

# Add init script to create job
COPY init.groovy.d/ /usr/share/jenkins/ref/init.groovy.d/
COPY $SEEDJOB_FILE /usr/local/seedJob.groovy
EOL

# Create init script directory
mkdir -p "$TEMP_DIR/init.groovy.d"

# Create initialization script to set up job from Jenkinsfile
cat > "$TEMP_DIR/init.groovy.d/create-job.groovy" << EOL
import jenkins.model.*
import hudson.model.*
import org.jenkinsci.plugins.workflow.job.WorkflowJob
import org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition
import org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition
import hudson.plugins.git.GitSCM
import hudson.plugins.git.BranchSpec
import hudson.plugins.git.UserRemoteConfig
import hudson.scm.NullSCM

def jenkins = Jenkins.getInstance()

// Create a pipeline job from Jenkinsfile
def jobName = "pipeline-from-jenkinsfile"
def job = jenkins.getItem(jobName)
if (job == null) {
    job = jenkins.createProject(WorkflowJob.class, jobName)
    
    // Read Jenkinsfile content
    def jenkinsfileContent = new File("/var/jenkins_home/Jenkinsfile").text
    
    // Create pipeline definition
    def flowDefinition = new CpsFlowDefinition(jenkinsfileContent, true)
    job.setDefinition(flowDefinition)
    
    println "Created pipeline job from Jenkinsfile"
} else {
    println "Job already exists"
}

jenkins.save()
EOL

# Copy the input files to the temp directory
cp "$JENKINSFILE" "$TEMP_DIR/"
cp "$PLUGINS_FILE" "$TEMP_DIR/"
cp "$JCASC_FILE" "$TEMP_DIR/"
cp "$SEEDJOB_FILE" "$TEMP_DIR/"

# Build custom Jenkins image
CUSTOM_IMAGE="jenkins/jenkins:2.375.3"
echo "Building custom Jenkins image..."
docker build -t "$CUSTOM_IMAGE" "$TEMP_DIR"

# Remove any existing container with the same name
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

# Run the Jenkins container
echo "Starting Jenkins container..."
docker run $DETACH \
  --name "$CONTAINER_NAME" \
  --network "$DOCKER_NETWORK" \
  -p "$PORT:8080" \
  -p "$AGENT_PORT:50000" \
  -v "$VOLUME:$JENKINS_HOME" \
  "$CUSTOM_IMAGE"

# Clean up temporary directory
rm -rf "$TEMP_DIR"

if [ -z "$DETACH" ]; then
  echo "Jenkins is running in interactive mode. Press Ctrl+C to stop."
else
  echo "Jenkins is running in detached mode."
  echo "Access Jenkins at http://localhost:$PORT"
  echo "To stop the container, run: docker stop $CONTAINER_NAME"
  echo "To view logs, run: docker logs $CONTAINER_NAME"
fi
