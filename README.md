# VPC Network Automated Jenkins Declarative Pipeline

Automates AWS VPC network creation using **Terraform**, driven by a **Jenkins Declarative Pipeline** running on a **Jenkins master–slave (agent) architecture**. The pipeline provisions a VPC with public/private subnets, an Internet Gateway, a NAT Gateway, and route tables — with state stored remotely in S3 — and can also tear everything down on demand.

---

## Architecture

```
                 ┌─────────────────────┐
                 │   Jenkins Master     │   (EC2 - Server 1)
                 │   Web UI :8080       │
                 └──────────┬───────────┘
                            │ SSH
                            ▼
                 ┌─────────────────────┐
                 │   Jenkins Agent      │   (EC2 - Server 2)
                 │   git + terraform    │
                 │   aws configure      │
                 └──────────┬───────────┘
                            │ terraform apply/destroy
                            ▼
                 ┌─────────────────────┐
                 │   AWS VPC            │
                 │   Public + Private   │
                 │   Subnet, IGW, NAT   │
                 └─────────────────────┘
```

- **Master**: hosts the Jenkins web UI, owns the pipeline job, dispatches builds to the agent.
- **Agent (slave)**: labeled `terraform-agent`; actually runs `terraform` and the AWS CLI against your account.
- **Terraform backend**: an S3 bucket (`terraform-vpc-state-bucket-declerative-1`) stores the remote state, created automatically by the pipeline if it doesn't already exist.

---

## Setup order (why this matters)

The master is touched **twice**, with the slave setup sandwiched in between — a few master-side steps can't happen until the slave exists:

1. **Master, round 1** — install Jenkins itself, and prep the `jenkins` OS user (shell, password, SSH key). None of this depends on the slave.
2. **Slave** — create its `jenkins` OS user, install Java/Git/Terraform, `aws configure`. This has to exist before the master can trust it.
3. **Master, round 2** — `ssh-copy-id` into the slave to establish the SSH trust. This is the step that genuinely can't run earlier — it logs into the slave's `jenkins` account, which didn't exist until step 2.
4. **Master — Jenkins UI** — create the admin user, add credentials, register the agent node. The "Launch via SSH" node setup needs the trust from step 3 to actually succeed.
5. **Master — Jenkins UI** — create and run the pipeline job.

The sections below follow this exact order.

---

## Repository layout

```
source-code/
├── Jenkinsfile        # Declarative pipeline: checkout → validate → plan → apply/destroy
├── backend.tf          # S3 remote backend config for Terraform state
├── provider.tf          # AWS provider (region ap-south-1, aws provider v6.12.0)
├── main.tf             # VPC, subnets, IGW, NAT gateway, route tables
├── s3.tf               # Optional S3 bucket resource
├── variable.tf         # Variable declarations
└── variable.tfvars     # Variable values used by `terraform plan/apply`
```

### What `main.tf` creates
- 1 VPC (`var.vpc_cidr`)
- 1 public subnet + 1 private subnet (in `var.availability_zone`)
- 1 Internet Gateway (attached to the VPC)
- 1 Elastic IP + 1 NAT Gateway (placed in the public subnet)
- 2 route tables — a public route table pointing at the IGW, a private route table pointing at the NAT Gateway — each associated with its respective subnet

Default values (`variable.tfvars`): region `ap-south-1`, VPC CIDR `10.0.0.0/16`, public subnet `10.0.1.0/24`, private subnet `10.0.2.0/24`, AZ `ap-south-1a`.

---

## Part 1 — Master, round 1: install Jenkins (EC2 Server 1)

Nothing here depends on the slave — do this whenever.

```bash
# Update packages
sudo yum update -y

# Add the Jenkins repo
sudo wget -O /etc/yum.repos.d/jenkins.repo https://pkg.jenkins.io/rpm-stable/jenkins.repo

# Import the Jenkins-CI GPG key
sudo rpm --import https://pkg.jenkins.io/rpm-stable/jenkins.io-2026.key
sudo yum upgrade -y

# Install Java (Jenkins requires a JDK)
sudo yum install java-21-amazon-corretto -y

# Install Jenkins
sudo yum install jenkins -y

# Enable and start the service
sudo systemctl enable jenkins
sudo systemctl start jenkins
sudo systemctl status jenkins
```

### Prep the `jenkins` OS user for SSH-based agent connections

```bash
# Confirm the jenkins user exists
grep jenkins /etc/passwd

# Give it a real login shell (default is /bin/false)
sudo usermod -s /bin/bash jenkins

# Set a password for the jenkins user
sudo passwd jenkins
```

Enable password authentication for SSH (needed once, to bootstrap key-based auth):

```bash
sudo vi /etc/ssh/sshd_config
# set: PasswordAuthentication yes
sudo systemctl restart sshd
```

Generate an SSH key pair as the `jenkins` user:

```bash
su - jenkins
ssh-keygen -t rsa -b 4096
```

**Stop here.** The next master step (`ssh-copy-id`) needs the slave's `jenkins` user to exist first — go set up Part 2 now, then come back to Part 3.

---

## Part 2 — Slave: prep the agent (EC2 Server 2)

```bash
# Create the jenkins user
sudo useradd jenkins
sudo passwd jenkins

# Allow password auth temporarily (same as master) so the master's key can be added
sudo vi /etc/ssh/sshd_config
# set: PasswordAuthentication yes
sudo systemctl restart sshd

# Install Java
sudo yum install java-21-amazon-corretto -y

# Install Git and Terraform
sudo yum install git -y
sudo yum install -y yum-utils
sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
sudo yum install terraform -y

# Configure AWS credentials for the jenkins user
su - jenkins
aws configure
# AWS Access Key ID / Secret Access Key / region (ap-south-1) / output format
```

Once this is done, the slave's `jenkins` user exists, has a password, and SSH password auth is enabled — it's ready to accept the master's `ssh-copy-id` connection in Part 3.

---

## Part 3 — Master, round 2: establish the SSH trust

Back on the **master**, as the `jenkins` user (same session as Part 1's `ssh-keygen`, or `su - jenkins` again):

```bash
ssh-copy-id jenkins@<agent-private-ip>
```

This is the step that actually can't happen until the slave is ready — it logs into the slave's `jenkins` account (using the password you set in Part 2) and appends the master's public key to `~jenkins/.ssh/authorized_keys` on the agent. After this, the master can SSH into the agent as `jenkins` without a password, which is what lets Jenkins launch the agent via SSH in Part 4.

Quick check before moving on:

```bash
ssh jenkins@<agent-private-ip>
# should log in with no password prompt
```

> Security note: enabling SSH password authentication (on both boxes) is convenient for initial setup/learning environments. In production, disable `PasswordAuthentication` again once key-based auth works, and prefer Jenkins credentials (SSH private key) over a static jenkins-user password.

---

## Part 4 — Master: configure Jenkins (Jenkins UI)

> Everything here happens through the Jenkins web UI on the **master**. Doing this before Part 3 will make the "Launch agents via SSH" step fail, since there'd be no trust yet.

1. **Open the Jenkins UI**: `http://<master-public-ip>:8080`
2. **Unlock Jenkins** using the initial admin password:
   ```bash
   sudo cat /var/lib/jenkins/secrets/initialAdminPassword
   ```
3. **Install suggested plugins**, then **create the first admin user** (username, password, full name, email).
4. **Add credentials** (Manage Jenkins → Credentials): add the SSH private key (or username/password) Jenkins will use to reach the agent, plus any Git credentials needed for the repo.
5. **Add the agent node** (Manage Jenkins → Nodes → New Node):
   - Name / description
   - Remote root directory (e.g. `/home/jenkins`) — the working directory on the agent
   - Labels: `terraform-agent` (must match the `agent { label 'terraform-agent' }` in the Jenkinsfile)
   - Usage: *Only build jobs with label expressions matching this node*
   - Launch method: **Launch agents via SSH**
     - Host: agent's private/public IP
     - Credentials: the SSH credential added above
     - Host Key Verification Strategy: set per your security policy (e.g. "Non verifying" for learning setups only)

---

## Part 5 — Master: create and run the pipeline

1. **New Item → Pipeline**, give it a name.
2. Under **Pipeline**, set:
   - Definition: **Pipeline script from SCM**
   - SCM: **Git**
   - Repository URL: `https://github.com/Harshadphule/VPC-Network-Automated-Jenkins-Declarative-Pipeline.git`
   - Branch: `main`
   - Script Path: `source-code/Jenkinsfile`
3. **Save**.
4. **Build with Parameters**:
   - `TERRAFORM_ACTION`: `apply` (provision) or `destroy` (tear down)
   - `DELETE_S3_BACKEND`: only set `true` alongside `destroy` if you also want the Terraform state bucket removed (learning/testing only — this deletes your remote state)
5. *(Optional)* **Build Triggers → Poll SCM**, schedule e.g. `* * * * *` to poll the repo every minute for changes.

### What the pipeline does (`Jenkinsfile`)
1. **Git Checkout** — pulls the repo on the agent
2. **Check Required Tools** — verifies `aws`, `terraform`, `python3`, and valid AWS credentials (`aws sts get-caller-identity`)
3. **Ensure Terraform Backend** — creates the S3 state bucket (with versioning) if it doesn't exist yet
4. **Terraform Init / Validate / Plan** — standard Terraform workflow against `variable.tfvars`
5. **Terraform Action** — runs `apply -auto-approve` or `destroy -auto-approve` based on the `TERRAFORM_ACTION` parameter
6. **Delete S3 Backend** *(conditional)* — only runs when `TERRAFORM_ACTION=destroy` **and** `DELETE_S3_BACKEND=true`; empties and deletes the state bucket, including all object versions

---

## Prerequisites checklist

- [ ] Two EC2 instances (Amazon Linux), security groups allow: 8080 (Jenkins UI, master), 22 (SSH, both)
- [ ] Master: Java 21, Jenkins installed and running (Part 1)
- [ ] Agent: Java 21, Git, Terraform, AWS CLI configured with credentials that can create VPC/EC2/S3 resources (Part 2)
- [ ] SSH trust set up master → agent via `ssh-copy-id jenkins@<agent-ip>`, run from the master **after** the agent's `jenkins` user exists (Part 3)
- [ ] Jenkins agent node configured with label `terraform-agent` (Part 4)
- [ ] Pipeline job pointing at this repo, script path `source-code/Jenkinsfile` (Part 5)

## Cleanup

Run the pipeline with `TERRAFORM_ACTION=destroy` to tear down the VPC and all associated networking resources. Only check `DELETE_S3_BACKEND` if you also want the Terraform state bucket permanently removed.