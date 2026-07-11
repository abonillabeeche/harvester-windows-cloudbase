terraform {
  required_version = ">= 1.5"
  required_providers {
    # Standard k8s provider — used for the Secret only.
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    # Community kubectl provider — used for the KubeVirt VM and Harvester
    # VirtualMachineImage CRDs. It's more forgiving with CRD field types
    # than the hashicorp/kubernetes provider's kubernetes_manifest, which
    # rejects the KubeVirt disk oneOf schema at apply time.
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}
