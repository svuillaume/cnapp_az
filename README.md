FortiCNAPP Terraform Provider Authentication

The FortiCNAPP Terraform provider (lacework) supports multiple authentication methods.

This README covers three options:

1. .lacework.toml — provider/CLI configuration
2. LW_* environment variables — direct environment authentication
3. Terraform variables — TF_VAR_* or terraform.tfvars

⸻

Option 1 — .lacework.toml

The Lacework/FortiCNAPP CLI can store your credentials in:

~/.lacework.toml

Example:

[default]
account = "YOUR_ACCOUNT"
api_key = "YOUR_API_KEY"
api_secret = "YOUR_API_SECRET"

Terraform provider:

provider "lacework" {}

Terraform will use the credentials available through the Lacework configuration.

Run:

terraform init
terraform plan

Do not commit .lacework.toml to Git.

Add it to .gitignore:

.lacework.toml

⸻

Option 2 — Environment Variables

The provider can authenticate directly using the following environment variables:

export LW_ACCOUNT="YOUR_ACCOUNT"
export LW_API_KEY="YOUR_API_KEY"
export LW_API_SECRET="YOUR_API_SECRET"

Terraform provider:

provider "lacework" {}

Run:

terraform init
terraform plan

The provider reads the credentials directly from the environment.

Windows PowerShell

$env:LW_ACCOUNT="YOUR_ACCOUNT"
$env:LW_API_KEY="YOUR_API_KEY"
$env:LW_API_SECRET="YOUR_API_SECRET"

This method is useful for CI/CD pipelines and temporary authentication.

⸻

Option 3 — Terraform Variables

Terraform can also receive the credentials through Terraform variables.

There are two ways to provide these variables:

* TF_VAR_* environment variables
* terraform.tfvars

3A — Using TF_VAR_*

Set:

export TF_VAR_lw_account="YOUR_ACCOUNT"
export TF_VAR_lw_api_key="YOUR_API_KEY"
export TF_VAR_lw_api_secret="YOUR_API_SECRET"

Define the variables in variables.tf:

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

Configure the provider:

provider "lacework" {
  account    = var.lw_account
  api_key    = var.lw_api_key
  api_secret = var.lw_api_secret
}

Terraform automatically maps:

TF_VAR_lw_account    → var.lw_account
TF_VAR_lw_api_key    → var.lw_api_key
TF_VAR_lw_api_secret → var.lw_api_secret

Then:

terraform init
terraform plan

⸻

3B — Using terraform.tfvars

Create:

terraform.tfvars

Add:

lw_account    = "YOUR_ACCOUNT"
lw_api_key    = "YOUR_API_KEY"
lw_api_secret = "YOUR_API_SECRET"

Use the same variables.tf:

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

Provider:

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

Important

Do not commit terraform.tfvars if it contains credentials.

Add it to .gitignore:

terraform.tfvars

⸻

Authentication Methods Summary

Method	Credentials	Provider Configuration
.lacework.toml	~/.lacework.toml	provider "lacework" {}
Environment	LW_ACCOUNT, LW_API_KEY, LW_API_SECRET	provider "lacework" {}
Terraform variables	TF_VAR_*	var.lw_*
terraform.tfvars	lw_* variables	var.lw_*

The important distinction is:

LW_*       → Read directly by the Lacework provider
TF_VAR_*   → Read by Terraform → becomes var.lw_*
tfvars     → Read by Terraform → becomes var.lw_*

For example:

LW_API_KEY
     │
     └──→ Lacework Provider
TF_VAR_lw_api_key
     │
     └──→ var.lw_api_key
              │
              └──→ Lacework Provider
terraform.tfvars
     │
     └──→ var.lw_api_key
              │
              └──→ Lacework Provider

Security

Never hard-code credentials in main.tf:

provider "lacework" {
  api_secret = "MY_SECRET"
}

Avoid committing credentials to Git.

Recommended .gitignore:

.lacework.toml
terraform.tfvars
*.tfstate
*.tfstate.*

For local development, .lacework.toml is convenient.

For automation and CI/CD, environment variables are generally easier to manage.

For Terraform-specific deployments, TF_VAR_* or terraform.tfvars can be used when the credentials need to be passed explicitly through Terraform variables.
