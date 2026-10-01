FortiCNAPP Terraform Provider Authentication

The FortiCNAPP Terraform provider (lacework) supports multiple authentication methods for Terraform deployments.

This README covers three authentication options:

1. .lacework.toml — Lacework/FortiCNAPP CLI configuration
2. LW_* environment variables — direct provider authentication
3. Terraform variables — TF_VAR_* or terraform.tfvars

⸻

Authentication Overview

Option	Method	Best Use
1	.lacework.toml	Local development
2	LW_* environment variables	CI/CD and temporary authentication
3A	TF_VAR_* environment variables	Terraform automation
3B	terraform.tfvars	Local Terraform testing

Security: Never commit API keys, API secrets, or other credentials to Git.

⸻

1. .lacework.toml

The Lacework/FortiCNAPP CLI can store your credentials in:

~/.lacework.toml

Example

[default]
account = "YOUR_ACCOUNT"
api_key = "YOUR_API_KEY"
api_secret = "YOUR_API_SECRET"

Terraform Provider

provider "lacework" {}

Terraform can use the credentials available through the Lacework configuration.

Run Terraform

terraform init
terraform plan

Protect .lacework.toml

Do not commit .lacework.toml to Git.

Add it to .gitignore:

.lacework.toml

⸻

2. Environment Variables

The Lacework/FortiCNAPP provider can authenticate directly using environment variables.

Linux / macOS

export LW_ACCOUNT="YOUR_ACCOUNT"
export LW_API_KEY="YOUR_API_KEY"
export LW_API_SECRET="YOUR_API_SECRET"

Terraform Provider

provider "lacework" {}

The provider reads the credentials directly from the environment.

Run Terraform

terraform init
terraform plan

Windows PowerShell

$env:LW_ACCOUNT="YOUR_ACCOUNT"
$env:LW_API_KEY="YOUR_API_KEY"
$env:LW_API_SECRET="YOUR_API_SECRET"

When to Use This Method

Environment variables are useful for:

* CI/CD pipelines
* Automation
* Temporary authentication
* Avoiding credentials in Terraform configuration files

⸻

3. Terraform Variables

Terraform can also receive the FortiCNAPP credentials through Terraform variables.

There are two approaches:

* 3A — TF_VAR_* environment variables
* 3B — terraform.tfvars

Both provide values to Terraform variables such as:

var.lw_account
var.lw_api_key
var.lw_api_secret

⸻

3A. Using TF_VAR_*

Terraform automatically maps environment variables beginning with TF_VAR_ to Terraform variables.

Set the Environment Variables

export TF_VAR_lw_account="YOUR_ACCOUNT"
export TF_VAR_lw_api_key="YOUR_API_KEY"
export TF_VAR_lw_api_secret="YOUR_API_SECRET"

Define variables.tf

variable "lw_account" {
  type      = string
  sensitive = true
}
variable "lw_api_key" {
  type      = string
  sensitive = true
}
variable "lw_api_secret" {
  type      = string
  sensitive = true
}

Configure the Provider

provider "lacework" {
  account    = var.lw_account
  api_key    = var.lw_api_key
  api_secret = var.lw_api_secret
}

Terraform Mapping

TF_VAR_lw_account
        |
        +----> var.lw_account
TF_VAR_lw_api_key
        |
        +----> var.lw_api_key
TF_VAR_lw_api_secret
        |
        +----> var.lw_api_secret

Then run:

terraform init
terraform plan

⸻

3B. Using terraform.tfvars

Terraform can also load the credentials from a terraform.tfvars file.

Create terraform.tfvars

lw_account    = "YOUR_ACCOUNT"
lw_api_key    = "YOUR_API_KEY"
lw_api_secret = "YOUR_API_SECRET"

Define variables.tf

variable "lw_account" {
  type      = string
  sensitive = true
}
variable "lw_api_key" {
  type      = string
  sensitive = true
}
variable "lw_api_secret" {
  type      = string
  sensitive = true
}

Configure the Provider

provider "lacework" {
  account    = var.lw_account
  api_key    = var.lw_api_key
  api_secret = var.lw_api_secret
}

Terraform automatically loads:

terraform.tfvars

when running:

terraform plan

or:

terraform apply

Protect terraform.tfvars

If it contains credentials, do not commit it to Git.

Add:

terraform.tfvars

to .gitignore.

⸻

Authentication Flow

The three authentication approaches work differently.

Option 1 — .lacework.toml

~/.lacework.toml
       |
       v
Lacework Provider

Provider configuration:

provider "lacework" {}

⸻

Option 2 — LW_* Environment Variables

LW_ACCOUNT
LW_API_KEY
LW_API_SECRET
       |
       v
Lacework Provider

Provider configuration:

provider "lacework" {}

⸻

Option 3A — TF_VAR_*

TF_VAR_lw_account
TF_VAR_lw_api_key
TF_VAR_lw_api_secret
       |
       v
Terraform
       |
       +----> var.lw_account
       +----> var.lw_api_key
       +----> var.lw_api_secret
                    |
                    v
            Lacework Provider

⸻

Option 3B — terraform.tfvars

terraform.tfvars
       |
       v
Terraform
       |
       +----> var.lw_account
       +----> var.lw_api_key
       +----> var.lw_api_secret
                    |
                    v
            Lacework Provider

⸻

Authentication Methods Summary

Method	Credentials	Provider Configuration
.lacework.toml	~/.lacework.toml	provider "lacework" {}
Environment	LW_ACCOUNT, LW_API_KEY, LW_API_SECRET	provider "lacework" {}
TF_VAR_*	Terraform environment variables	var.lw_*
terraform.tfvars	lw_* variables	var.lw_*

⸻

Key Difference: LW_* vs TF_VAR_*

This distinction is important.

LW_*

LW_API_KEY
     |
     +----> Lacework Provider

The Lacework provider reads the environment variable directly.

TF_VAR_*

TF_VAR_lw_api_key
     |
     +----> Terraform
                |
                +----> var.lw_api_key
                            |
                            +----> Lacework Provider

Terraform reads the TF_VAR_* environment variable and makes it available as a Terraform variable.

terraform.tfvars

terraform.tfvars
     |
     +----> Terraform
                |
                +----> var.lw_api_key
                            |
                            +----> Lacework Provider

⸻

Security

Do Not Hard-Code Credentials

Avoid putting credentials directly into main.tf:

provider "lacework" {
  account    = "MY_ACCOUNT"
  api_key    = "MY_API_KEY"
  api_secret = "MY_SECRET"
}

Credentials should be supplied through one of the supported authentication methods.

Recommended .gitignore

# Lacework credentials
.lacework.toml
# Terraform variables containing credentials
terraform.tfvars
# Terraform state
*.tfstate
*.tfstate.*
# Terraform working directory
.terraform/

Important: sensitive = true prevents Terraform from displaying a variable value in normal CLI output, but it does not encrypt the value. Treat terraform.tfvars and Terraform state files as sensitive when they contain credentials.

⸻

Recommended Usage

Local Development

Use:

~/.lacework.toml

This keeps credentials outside the Terraform project.

CI/CD and Automation

Use:

LW_ACCOUNT
LW_API_KEY
LW_API_SECRET

or:

TF_VAR_lw_account
TF_VAR_lw_api_key
TF_VAR_lw_api_secret

depending on how your CI/CD system manages credentials and Terraform variables.

Local Terraform Testing

Use:

terraform.tfvars

when you need to explicitly provide Terraform variables.

Ensure terraform.tfvars is excluded from Git if it contains credentials.

⸻

Quick Reference

Option 1

~/.lacework.toml
provider "lacework" {}

Option 2

export LW_ACCOUNT="YOUR_ACCOUNT"
export LW_API_KEY="YOUR_API_KEY"
export LW_API_SECRET="YOUR_API_SECRET"
provider "lacework" {}

Option 3A

export TF_VAR_lw_account="YOUR_ACCOUNT"
export TF_VAR_lw_api_key="YOUR_API_KEY"
export TF_VAR_lw_api_secret="YOUR_API_SECRET"
provider "lacework" {
  account    = var.lw_account
  api_key    = var.lw_api_key
  api_secret = var.lw_api_secret
}

Option 3B

terraform.tfvars
lw_account    = "YOUR_ACCOUNT"
lw_api_key    = "YOUR_API_KEY"
lw_api_secret = "YOUR_API_SECRET"
provider "lacework" {
  account    = var.lw_account
  api_key    = var.lw_api_key
  api_secret = var.lw_api_secret
}
