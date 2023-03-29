terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "0.6.4"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.16.0"
    }
  }
}

variable "namespace" {
  type        = string
  sensitive   = true
  description = "The namespace to create workspaces in (must exist prior to creating workspaces)"
  default     = "coder"
}

variable "shm_size" {
  type        = string
  sensitive   = true
  description = "The size limit for shared memory (if a GPU claim is active)"
  default     = "8G"
}

variable "gpu" {
  type        = bool
  description = "Allocate a GPU?"
  default     = false
}

data "coder_workspace" "me" {}

resource "coder_agent" "main" {
  os             = "linux"
  arch           = "amd64"
  startup_script = <<EOT
    #!/bin/bash

    # home folder can be empty, so copying default bash settings
    if [ ! -f ~/.profile ]; then
      cp /etc/skel/.profile $HOME
    fi
    if [ ! -f ~/.bashrc ]; then
      cp /etc/skel/.bashrc $HOME
      echo ". /etc/profile.d/conda.sh" >> $HOME/.bashrc
      echo "conda activate /datashare/envs/mlcourse" >> $HOME/.bashrc
    fi

    # install code-server
    curl -fsSL https://code-server.dev/install.sh | sh | tee code-server-install.log

    # install extensions
    code-server --install-extension ms-python.python | tee -a code-server-install.log

    # start code-server
    code-server --auth none --port 13337 | tee -a code-server-install.log &
  EOT
}

# code-server
resource "coder_app" "code-server" {
  agent_id     = coder_agent.main.id
  slug         = "code-server"
  display_name = "code-server"
  icon         = "/icon/code.svg"
  url          = "http://localhost:13337?folder=/home/coder"
  subdomain    = false
  share        = "owner"

  healthcheck {
    url       = "http://localhost:13337/healthz"
    interval  = 3
    threshold = 30
  }
}

resource "kubernetes_persistent_volume_claim" "home" {
  metadata {
    name      = "coder-${lower(data.coder_workspace.me.owner)}-${lower(data.coder_workspace.me.name)}-home"
    namespace = var.namespace
  }
  count = 1  # don't delete this volume after stopping the workspace
  wait_until_bound = false
  spec {
    access_modes = ["ReadWriteOnce"]
    storage_class_name = "efs-workspacehomes"
    resources {
      requests = {
        # Storage specs are irrelevant for EFS volumes
        storage = "10Gi"
      }
    }
  }
}

resource "kubernetes_pod" "main" {
  count = data.coder_workspace.me.start_count
  metadata {
    name      = "coder-${lower(data.coder_workspace.me.owner)}-${lower(data.coder_workspace.me.name)}"
    namespace = var.namespace
    # Prevent the autoscaler from evicting this pod.
    labels = {
      "cluster-autoscaler.kubernetes.io/safe-to-evict" = "false"
    }
  }
  spec {
    security_context {
      run_as_user = "1000"
      fs_group    = "1000"
    }
    affinity {
      node_affinity {
        required_during_scheduling_ignored_during_execution {
          node_selector_term {
            match_expressions {
              key      = "workspace_node"
              operator = "In"
              values   = [ "true" ]
            }
            match_expressions {
              key      = "k8s.amazonaws.com/accelerator"
              operator = var.gpu == true ? "Exists" : "DoesNotExist"
            }
          }
        }
      }
    }
    container {
      name    = "dev"
      # Replace with $repo_uri from the installation script.
      image   = "<repo uri>:latest"
      command = ["sh", "-c", coder_agent.main.init_script]
      security_context {
        run_as_user = "1000"
      }
      env {
        name  = "CODER_AGENT_TOKEN"
        value = coder_agent.main.token
      }
      volume_mount {
        mount_path = "/home/coder"
        name       = "home"
        read_only  = false
      }
      volume_mount {
        mount_path = "/datashare"
        name       = "datashare"
        read_only  = true
      }
      dynamic volume_mount {
        for_each = var.gpu == true ? ["/dev/shm"] : []
        content {
          mount_path = volume_mount.value
          name       = "shared-memory"
          read_only  = false
        }
      }
      dynamic resources {
        for_each = var.gpu == true ? ["1"] : []
        content {
          limits = {
            "nvidia.com/gpu" = resources.value
          }
        }
      }
    }

    volume {
      name = "home"
      persistent_volume_claim {
        claim_name = kubernetes_persistent_volume_claim.home[0].metadata.0.name
        read_only  = false
      }
    }
    volume {
      name = "datashare"
      persistent_volume_claim {
        claim_name = "efs-claim"
        read_only  = true
      }
    }
    dynamic volume {
      for_each = var.gpu == true ? [var.shm_size] : []
      content {
        name = "shared-memory"
        empty_dir {
          medium = "Memory"
          size_limit = volume.value
        }
      }
    }
  }

  timeouts {
    create = "15m"
  }
}
