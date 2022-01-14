# vpc resource
resource "google_compute_network" "final_vpc" {
  project                 = "gcp-gke-project-338217"
  name                    = "final-vpc"
  auto_create_subnetworks = false
}

# Management subnet, includes nat-gateway and private VM 
resource "google_compute_subnetwork" "management" {
  name          = "management-subnet"
  ip_cidr_range = "10.0.10.0/24"
  region        = "europe-west1"
  network       = google_compute_network.final_vpc.id
}

# Restricted subnet, has a private standard GKE cluster
resource "google_compute_subnetwork" "restricted" {
  name          = "restricted-subnet"
  ip_cidr_range = "10.0.11.0/24"
  region        = "europe-west1"
  network       = google_compute_network.final_vpc.id
}

# Router and nat-gateway
resource "google_compute_router" "final_router" {
  name    = "final-router"
  region  = google_compute_subnetwork.management.region
  network = google_compute_network.final_vpc.id

  bgp {
    asn = 64514
  }
}
resource "google_compute_router_nat" "final_nat_gateway" {
  name                               = "final-router-nat"
  router                             = google_compute_router.final_router.name
  region                             = google_compute_router.final_router.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"
  subnetwork {
    name                    = google_compute_subnetwork.management.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
}

resource "google_service_account" "instance_sarvice" {
  account_id   = "instance-service-account-id"
  display_name = "final_Service_Account"
}
resource "google_project_iam_binding" "final_project" {
  project = "gcp-gke-project-338217"
  role    = "roles/container.admin"

  members = [
    "serviceAccount:${google_service_account.instance_sarvice.email}"
  ]
}

# private VM resource
resource "google_compute_instance" "managementinstance" {
  name         = "management-vm"
  machine_type = "e2-micro"
  zone         = "europe-west1-b"

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-9"
    }
  }
  network_interface {
    network    = google_compute_network.final_vpc.id
    subnetwork = google_compute_subnetwork.management.id
  }
  # Google recommends custom service accounts that have cloud-platform scope and permissions granted via IAM Roles.
  #service_account = google_service_account.instance_sa.email
  #oauth_scopes    = [
  # "https://www.googleapis.com/auth/cloud-platform"
  #]
  service_account {
    # Google recommends custom service accounts that have cloud-platform scope and permissions granted via IAM Roles.
    email  = google_service_account.instance_sarvice.email
    scopes = ["cloud-platform"]
  }
}

# firewall role to allow access only through IAP
resource "google_compute_firewall" "default-fw" {
  name    = "test-firewall"
  network = google_compute_network.final_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["80", "22"]
  }
  direction     = "INGRESS"
  source_ranges = ["35.235.240.0/20"]
}

# k8s cluster
resource "google_container_cluster" "final_cluster" {
  name       = "final-gke-cluster"
  location   = "europe-west1"
  network    = google_compute_network.final_vpc.id
  subnetwork = google_compute_subnetwork.restricted.id
  
  private_cluster_config {
    master_ipv4_cidr_block  = "172.16.0.0/28"
    enable_private_nodes    = true
    enable_private_endpoint = true
  }

  master_authorized_networks_config {
    cidr_blocks {
      cidr_block = "10.0.10.0/24"
    }
  }
  ip_allocation_policy {
    cluster_ipv4_cidr_block  = "/21"
    services_ipv4_cidr_block = "/21"
  }

  # We can't create a cluster with no node pool defined, but we want to only use
  # separately managed node pools. So we create the smallest possible default
  # node pool and immediately delete it.
  remove_default_node_pool = true
  initial_node_count       = 1
}

resource "google_service_account" "cluster_sarvice" {
  account_id   = "service-account-id"
  display_name = "Service Account"
}
resource "google_project_iam_binding" "final_iam_cluster" {
  project = "gcp-gke-project-338217"
  role    = "roles/container.admin"

  members = [
    "serviceAccount:${google_service_account.cluster_sarvice.email}"
  ]
}

resource "google_container_node_pool" "final_nodes" {
  name       = "final-node-pool"
  location   = "europe-west1"
  cluster    = google_container_cluster.final_cluster.name
  node_count = 1

  node_config {
    preemptible  = false
    machine_type = "e2-micro"

    # Google recommends custom service accounts that have cloud-platform scope and permissions granted via IAM Roles.
    service_account = google_service_account.cluster_sarvice.email
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}