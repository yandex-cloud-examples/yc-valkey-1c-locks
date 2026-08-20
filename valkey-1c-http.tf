# Infrastructure for Yandex Cloud Managed Service for Valkey cluster and Ubuntu VM
#
# RU: https://cloud.yandex.ru/docs/managed-valkey/tutorials/1c-valkey-locks
# EN: https://cloud.yandex.com/en/docs/managed-valkey/tutorials/1c-valkey-locks

# Specify the following settings
locals {
  http_port       =    # Set the HTTP-port for connections to the lock server
  lock_key_prefix = "" # Set the prefix for lock keys in Valkey cluster
  valkey_password = "" # Set the Managed Valkey cluster password

  # The following settings are predefined. Change them only if necessary.
  cloud_init      = <<-EOT
    #cloud-config
    package_update: true

    packages:
      - build-essential
      - git
      - curl  
      - ca-certificates

    write_files:
      - path: /etc/http-lock-valkey.env
        owner: root:root
        permissions: '0640'
        content: |
          HTTP_ADDR=:${local.http_port}
          VALKEY_ADDR=${yandex_mdb_redis_cluster_v2.valkey.hosts["host-1"].fqdn}:6379
          VALKEY_USER=default
          VALKEY_PASSWORD='${local.valkey_password}'
          DEFAULT_LOCK_TTL=30s
          LOCK_KEY_PREFIX=${local.lock_key_prefix}
      - path: /etc/systemd/system/http-lock-valkey.service
        owner: root:root
        permissions: '0644'
        content: |
          [Unit]
          Description=1C HTTP Lock Valkey demo service
          Documentation=https://git.sourcecraft.dev/valkey/webinar-260624-1c-example
          After=network-online.target
          Wants=network-online.target

          [Service]
          Type=simple
          User=http-lock
          Group=http-lock
          EnvironmentFile=/etc/http-lock-valkey.env
          ExecStart=/usr/local/bin/http-lock-valkey
          Restart=on-failure
          RestartSec=2
          NoNewPrivileges=true

          [Install]
          WantedBy=multi-user.target

    runcmd:
      - useradd --system --no-create-home --shell /usr/sbin/nologin http-lock || true
      - curl -fsSL https://go.dev/dl/go${local.go_version}.linux-amd64.tar.gz -o /tmp/go.tar.gz
      - printf '%s  %s\n' ${local.go_sha256} /tmp/go.tar.gz | sha256sum --check -
      - rm -rf /usr/local/go
      - tar -C /usr/local -xzf /tmp/go.tar.gz
      - rm -f /tmp/go.tar.gz
      - rm -rf /opt/1c-http-lock
      - git clone --depth 1 --branch main ${local.repo_url} /opt/1c-http-lock
      - cd /opt/1c-http-lock/http-lock-valkey && HOME=/root /usr/local/go/bin/go build -o /usr/local/bin/http-lock-valkey .
      - chown root:http-lock /usr/local/bin/http-lock-valkey
      - chmod 0750 /usr/local/bin/http-lock-valkey
      - chown root:http-lock /etc/http-lock-valkey.env
      - chmod 0640 /etc/http-lock-valkey.env
      - systemctl daemon-reload
      - systemctl enable --now http-lock-valkey.service
  EOT
  go_version      = "1.26.2" # Required Go version
  go_sha256       = "990e6b4bbba816dc3ee129eaeaf4b42f17c2800b88a2166c265ac1a200262282" # Control sum for the Go installation package
  prefix          = "onec-http-lock" # Сommon prefix for the names of resources
  repo_url        = "https://git.sourcecraft.dev/valkey/webinar-260624-1c-example.git" # Repository with HTTP-server source code
  ubuntu_image_id = "fd83ergat2e815oohe7o" # Ubuntu image ID
  v4_cidr         = "10.128.0.0/24" # CIDR block for the subnet in the ru-central1-a availability zone
  zone            = "ru-central1-a" # Availability zone for resources
}

resource "terraform_data" "cloud_init" {
  triggers_replace = sha256(local.cloud_init)
}

resource "yandex_vpc_network" "net" {
  description = "Network for the Managed Service for Valkey cluster and VM"
  name        = "${local.prefix}-net"
}

resource "yandex_vpc_subnet" "subnet" {
  description    = "Subnet in the ru-central1-a availability zone"
  name           = "${local.prefix}-subnet-${local.zone}"
  network_id     = yandex_vpc_network.net.id
  zone           = local.zone
  v4_cidr_blocks = [local.v4_cidr]
}

resource "yandex_vpc_security_group" "valkey" {
  description = "Security group for the Managed Service for Valkey cluster"
  name        = "${local.prefix}-valkey-sg"
  network_id  = yandex_vpc_network.net.id

  ingress {
    description       = "Allow the VM to reach the Valkey port over the private network only"
    protocol          = "TCP"
    port              = 6379
    security_group_id = yandex_vpc_security_group.vm.id
  }

  egress {
    description    = "Allow replies back to the VM"
    protocol       = "ANY"
    v4_cidr_blocks = [local.v4_cidr]
  }
}

resource "yandex_vpc_security_group" "vm" {
  description = "Security group for the VM with the lock HTTP-server"
  name        = "${local.prefix}-vm-sg"
  network_id  = yandex_vpc_network.net.id

  ingress {
    description    = "Allow connections to public HTTP service port only"
    protocol       = "TCP"
    port           = local.http_port
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description    = "Allow internet and private VPC connections"
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "yandex_mdb_redis_cluster_v2" "valkey" {
  description = "Managed Service for Valkey cluster"
  name        = local.prefix
  environment = "PRODUCTION"
  network_id  = yandex_vpc_network.net.id
  tls_enabled = false

  config = {
    version  = "9.1-valkey"
    password = local.valkey_password
  }

  announce_hostnames = true

  access = {
    web_sql = true
  }

  modules = {
    valkey_search = { enabled = false }
    valkey_json   = { enabled = false }
    valkey_bloom  = { enabled = false }
  }

  resources = {
    resource_preset_id = "hm3-c2-m8" # 2 vCPU, 8 GB RAM
    disk_type_id       = "network-ssd"
    disk_size          = 16 # GB
  }

  security_group_ids = [yandex_vpc_security_group.valkey.id]

  hosts = {
    "host-1" = {
      zone      = local.zone
      subnet_id = yandex_vpc_subnet.subnet.id
    }
  }
}

resource "yandex_compute_instance" "vm" {
  description = "Virtual machine with Ubuntu and HTTP-server"
  name        = "${local.prefix}-vm"
  zone        = local.zone
  platform_id = "standard-v2"

  resources {
    cores  = 2
    memory = 2
  }

  boot_disk {
    initialize_params {
      image_id = local.ubuntu_image_id
      size     = 20 # GB
      type     = "network-ssd"
    }
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.subnet.id
    nat                = true
    ipv4               = true
    security_group_ids = [yandex_vpc_security_group.vm.id]
  }

  metadata = {
    user-data = local.cloud_init
  }

  lifecycle {
    replace_triggered_by = [terraform_data.cloud_init]
  }
}

output "vm_public_ip" {
  description = "Public IPv4 of the 1C HTTP Lock demo VM"
  value       = yandex_compute_instance.vm.network_interface[0].nat_ip_address
}

output "http_url" {
  description = "HTTP endpoint of the 1C HTTP Lock server"
  value       = "http://${yandex_compute_instance.vm.network_interface[0].nat_ip_address}:${local.http_port}"
}
