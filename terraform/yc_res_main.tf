variable "folder_id" {
  type = string
}

variable "provider_key_path" {
  type = string
}

locals {
  folder_id = var.folder_id
  provider_key_path = var.provider_key_path
  service-accounts = toset([
    "alexeit-catgpt-sa",
  ])
#  catgpt-sa-roles = toset([
#    "container-registry.images.puller",
#    "monitoring.editor"
#  ])
   catgpt-sa-roles = toset([
     "container-registry.images.puller",
     "monitoring.editor",
     "editor"
   ])
}

resource "yandex_vpc_network" "foo" {}

resource "yandex_vpc_subnet" "foo" {
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.foo.id
  v4_cidr_blocks = ["10.5.0.0/24"]
  route_table_id = yandex_vpc_route_table.catgpt-rt.id
}

resource "yandex_vpc_gateway" "nat_gateway" {
  name = "catgpt-gateway"
  shared_egress_gateway {}
}

resource "yandex_vpc_route_table" "catgpt-rt" {
  name       = "catgpt-rt"
  network_id = yandex_vpc_network.foo.id

  static_route {
    destination_prefix = "0.0.0.0/0"
    gateway_id         = yandex_vpc_gateway.nat_gateway.id
  }
}


##resource "yandex_container_registry" "registry1" {
#  name = "registry1"
#}

resource "yandex_iam_service_account" "service-accounts" {
  for_each = local.service-accounts
  name     = each.key
}
resource "yandex_resourcemanager_folder_iam_member" "catgpt-roles" {
  for_each  = local.catgpt-sa-roles
  folder_id = local.folder_id
  member    = "serviceAccount:${yandex_iam_service_account.service-accounts["alexeit-catgpt-sa"].id}"
  role      = each.key
}

data "yandex_compute_image" "coi" {
  family = "container-optimized-image"
}

resource "yandex_vpc_security_group" "test-sg" {
  name = "test-sg"
  description = "sg for catgpt instance"
  network_id = "${yandex_vpc_network.foo.id}"

  ingress {
    protocol = "TCP"
    v4_cidr_blocks = ["10.5.0.0/24"]
    from_port = 0
    to_port = 65535
  }

  egress {
    protocol = "TCP"
    v4_cidr_blocks = ["0.0.0.0/0"]
    from_port = 0
    to_port = 65535
  }
}


resource "yandex_compute_instance_group" "catgpt-group" {
    name = "catgpt-group"
    service_account_id = yandex_iam_service_account.service-accounts["alexeit-catgpt-sa"].id
    folder_id = local.folder_id
    depends_on = [
      yandex_resourcemanager_folder_iam_member.catgpt-roles
    ]
    instance_template {
      platform_id = "standard-v2"
      service_account_id = yandex_iam_service_account.service-accounts["alexeit-catgpt-sa"].id
      resources {
        cores         = 2
        memory        = 1
        core_fraction = 5
      }
      scheduling_policy {
        preemptible = true
      }
      network_interface {
        network_id     = yandex_vpc_network.foo.id
        subnet_ids = [yandex_vpc_subnet.foo.id]
        nat = false
      }
      boot_disk {
        initialize_params {
          type = "network-hdd"
          size = "30"
          image_id = data.yandex_compute_image.coi.id
        }
      }
      metadata = {
        user-data = file("./cloud-init.yaml")
        docker-compose = file("${path.module}/docker-compose.yaml")
        ssh-keys  = "ubuntu:${file("~/.ssh/ansible_rsa.pub")}"
      }
    }
    scale_policy {
      fixed_scale {
        size = 2
      }
    }
    allocation_policy {
      zones = ["ru-central1-a"]
    }
    deploy_policy {
      max_unavailable = 2
      max_creating = 2
      max_expansion = 2
      max_deleting = 2
    }
}
 
resource "yandex_lb_target_group" "catgpt-tg" {
  name      = "catgpt-tg"
  target {
    subnet_id = "${yandex_vpc_subnet.foo.id}"
    address   = "${yandex_compute_instance_group.catgpt-group.instances[0].network_interface[0].ip_address}"
  }
  target {
    subnet_id = "${yandex_vpc_subnet.foo.id}"
    address   = "${yandex_compute_instance_group.catgpt-group.instances[1].network_interface[0].ip_address}"
  }
}

resource "yandex_lb_network_load_balancer" "catgpt-lb" {
  name = "catgpt-lb"
  type = "external"
  deletion_protection = false
  listener {
    name = "catgpt"
    port = 8080
    external_address_spec {
      ip_version = "ipv4"
    }
  }
  attached_target_group {
    target_group_id = yandex_lb_target_group.catgpt-tg.id
    healthcheck {
      name = "http"
        http_options {
          port = 8080
          path = "/ping"
        }
    }
  }
}

output "instances_ip_addr" {
  value = ["${yandex_compute_instance_group.catgpt-group.instances[0].network_interface[0].ip_address}", "${yandex_compute_instance_group.catgpt-group.instances[1].network_interface[0].ip_address}"]
}

