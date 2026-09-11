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

## Part 1 — Provision the Jenkins Master (EC2 Server 1)

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

### Configure the `jenkins` OS user for SSH-based agent connections

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

Generate an SSH key pair as the `jenkins` user (used to connect to the agent):

```bash
su - jenkins
ssh-keygen -t rsa -b 4096
# copy the public key (~/.ssh/id_rsa.pub) — you'll add it to the agent's authorized_keys
```

> Security note: enabling SSH password authentication is convenient for initial setup/learning environments. In production, disable it again once key-based auth works, and prefer Jenkins credentials (SSH private key) over a static jenkins-user password.

---

## Part 2 — Provision the Jenkins Agent / Slave (EC2 Server 2)

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

Add the master's public key to `~jenkins/.ssh/authorized_keys` on this agent so the master can SSH in as `jenkins` without a password.

---

## Part 3 — Configure Jenkins (done on the Master server)

> Everything in this section happens through the Jenkins web UI on the **master** — you're not running anything on the agent/slave console here. The "Launch via SSH" step below is the master reaching out *to* the agent, not something done on the agent itself.

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

## Part 4 — Create and Run the Pipeline

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
- [ ] Master: Java 21, Jenkins installed and running
- [ ] Agent: Java 21, Git, Terraform, AWS CLI configured with credentials that can create VPC/EC2/S3 resources
- [ ] SSH trust set up from master → agent (jenkins user)
- [ ] Jenkins agent node configured with label `terraform-agent`
- [ ] Pipeline job pointing at this repo, script path `source-code/Jenkinsfile`

## Cleanup

Run the pipeline with `TERRAFORM_ACTION=destroy` to tear down the VPC and all associated networking resources. Only check `DELETE_S3_BACKEND` if you also want the Terraform state bucket permanently removed.