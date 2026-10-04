terraform {
  required_providers {
    oci = {
      source = "oracle/oci"
    }
  }
}

provider "oci" {
  region = var.region
}

resource "oci_core_vcn" "vcn_1" {
  compartment_id = var.tenancy_ocid
  cidr_blocks    = ["10.0.0.0/16"]
  display_name   = "${var.prefix}-vcn-1"
  dns_label      = var.prefix

  freeform_tags = {
    Team = var.team_tag
  }
}

resource "oci_core_subnet" "subnet_1" {
  compartment_id = var.tenancy_ocid
  vcn_id         = oci_core_vcn.vcn_1.id
  cidr_block     = "10.0.1.0/24"
  display_name   = "${var.prefix}-subnet-1"
  dns_label      = "subnet1"
  route_table_id = oci_core_route_table.rt_1.id

  freeform_tags = {
    Team = var.team_tag
  }
}

resource "oci_core_internet_gateway" "igw_1" {
  compartment_id = var.tenancy_ocid
  vcn_id         = oci_core_vcn.vcn_1.id
  display_name   = "${var.prefix}-igw-1"

  freeform_tags = {
    Team = var.team_tag
  }
}

resource "oci_core_route_table" "rt_1" {
  compartment_id = var.tenancy_ocid
  vcn_id         = oci_core_vcn.vcn_1.id
  display_name   = "${var.prefix}-rt-1"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.igw_1.id
  }

  freeform_tags = {
    Team = var.team_tag
  }
}

resource "oci_core_network_security_group" "nsg_1" {
  compartment_id = var.tenancy_ocid
  vcn_id         = oci_core_vcn.vcn_1.id
  display_name   = "${var.prefix}-nsg-1"

  freeform_tags = {
    Team = var.team_tag
  }
}

resource "oci_core_network_security_group_security_rule" "ingress_1" {
  for_each = { for rule in local.ingress_rules : "${rule.protocol}-${rule.port}" => rule }

  network_security_group_id = oci_core_network_security_group.nsg_1.id
  direction                 = "INGRESS"
  protocol                  = each.value.protocol == "tcp" ? "6" : "17"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"

  dynamic "tcp_options" {
    for_each = each.value.protocol == "tcp" ? [each.value.port] : []
    content {
      destination_port_range {
        min = tcp_options.value
        max = tcp_options.value
      }
    }
  }

  dynamic "udp_options" {
    for_each = each.value.protocol == "udp" ? [each.value.port] : []
    content {
      destination_port_range {
        min = udp_options.value
        max = udp_options.value
      }
    }
  }
}

resource "oci_core_network_security_group_security_rule" "egress_1" {
  network_security_group_id = oci_core_network_security_group.nsg_1.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
}

resource "oci_identity_dynamic_group" "dg_1" {
  compartment_id = var.tenancy_ocid
  name           = "${var.prefix}-dg-1"
  description    = "`${var.prefix}` `instance-1` principal"
  matching_rule  = "instance.compartment.id = '${var.tenancy_ocid}'"

  freeform_tags = {
    Team = var.team_tag
  }
}

resource "oci_identity_policy" "policy_1" {
  compartment_id = var.tenancy_ocid
  name           = "${var.prefix}-policy-1"
  description    = "`${var.prefix}` `dg-1`: read Vault secrets, read/write Object Storage assets"

  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.dg_1.name} to read secret-bundles in tenancy where target.vault.id = '${oci_kms_vault.vault_1.id}'",
    "Allow dynamic-group ${oci_identity_dynamic_group.dg_1.name} to read objects in tenancy where all {target.bucket.name = '${var.bucket_name}', request.permission = 'OBJECT_READ', any {${local.read_object_cond}}}",
    "Allow dynamic-group ${oci_identity_dynamic_group.dg_1.name} to manage objects in tenancy where all {target.bucket.name = '${var.bucket_name}', any {request.permission = 'OBJECT_CREATE', request.permission = 'OBJECT_OVERWRITE'}, any {${local.write_object_cond}}}",
  ]

  freeform_tags = {
    Team = var.team_tag
  }
}

resource "oci_kms_vault" "vault_1" {
  compartment_id = var.tenancy_ocid
  display_name   = "${var.prefix}-vault-1"
  vault_type     = "DEFAULT"

  freeform_tags = {
    Team = var.team_tag
  }
}

resource "oci_kms_key" "key_1" {
  compartment_id      = var.tenancy_ocid
  display_name        = "${var.prefix}-key-1"
  management_endpoint = oci_kms_vault.vault_1.management_endpoint
  protection_mode     = "SOFTWARE"

  key_shape {
    algorithm = "AES"
    length    = 32
  }

  freeform_tags = {
    Team = var.team_tag
  }
}

resource "oci_vault_secret" "github_username" {
  compartment_id = var.tenancy_ocid
  vault_id       = oci_kms_vault.vault_1.id
  key_id         = oci_kms_key.key_1.id
  secret_name    = "${var.prefix}-github_username"

  secret_content {
    content_type = "BASE64"
    content      = base64encode(var.github_username)
  }

  freeform_tags = {
    Team = var.team_tag
  }
}

resource "oci_vault_secret" "github_access_token" {
  compartment_id = var.tenancy_ocid
  vault_id       = oci_kms_vault.vault_1.id
  key_id         = oci_kms_key.key_1.id
  secret_name    = "${var.prefix}-github_access_token"

  secret_content {
    content_type = "BASE64"
    content      = base64encode(var.github_access_token)
  }

  freeform_tags = {
    Team = var.team_tag
  }
}

data "oci_objectstorage_namespace" "ns" {}

data "oci_objectstorage_bucket" "asset" {
  namespace = data.oci_objectstorage_namespace.ns.namespace
  name      = var.bucket_name
}

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

data "oci_core_images" "ubuntu" {
  compartment_id           = var.tenancy_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "26.04"
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

locals {
  ingress_rules = [
    { protocol = "tcp", port = 22 },
    { protocol = "tcp", port = 80 },
    { protocol = "tcp", port = 81 },
    { protocol = "tcp", port = 443 },
    { protocol = "udp", port = 443 },
    { protocol = "tcp", port = 3001 },
  ]

  bucket_asset_keys = [
    "compose.yaml",
    "prometheus.yml",
    ".env",
  ]

  # bucket_asset_keys에서 dump/xxx로 관리하지 않은 이유는 bucket_dump_keys에 권한이 다르게 붙기 때문
  bucket_dump_keys = [
    "trading.dump",
    "prometheus.tgz"
  ]

  read_object_names  = concat(local.bucket_asset_keys, [for k in local.bucket_dump_keys : "dump/${k}"], ["scratch/*"])
  write_object_names = concat([for k in local.bucket_dump_keys : "dump/${k}"], ["scratch/*"])

  read_object_cond  = join(", ", [for n in local.read_object_names : "target.object.name = '${n}'"])
  write_object_cond = join(", ", [for n in local.write_object_names : "target.object.name = '${n}'"])

  bootstrap = <<-EOF
  #!/bin/bash
  set -euxo pipefail

  timedatectl set-timezone Asia/Seoul

  LOG_FILE="/var/log/bootstrap.log"
  exec > >(tee -a $LOG_FILE) 2>&1

  echo "BOOTSTRAP START"

  sudo iptables -D INPUT -j REJECT --reject-with icmp-host-prohibited || true
  sudo iptables -D FORWARD -j REJECT --reject-with icmp-host-prohibited || true
  sudo netfilter-persistent save || true

  echo "BOOTSTRAP_ENV_PASSWORD=${var.password}" >> /etc/environment
  echo "BOOTSTRAP_ENV_APPLICATION_DOMAIN=${var.application_domain}" >> /etc/environment
  source /etc/environment

  echo "================ 1. Set up Docker ================"
  # Reserved Public IP는 인스턴스 생성 후 연결되므로, 연결 전엔 외부 통신 불가 → apt 저장소에 닿을 때까지 재시도 (최대 10분)
  SECONDS=0
  until sudo apt-get update --error-on=any -o Acquire::http::Timeout=10 -o Acquire::https::Timeout=10 -o Acquire::Retries=0; do
    [ "$SECONDS" -ge 600 ] && { echo "network not ready after 10min"; exit 1; }
    sleep 5
  done
  sudo apt-get install -y ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc

  sudo tee /etc/apt/sources.list.d/docker.sources <<DOCKER_SOURCES
  Types: deb
  URIs: https://download.docker.com/linux/ubuntu
  Suites: $(. /etc/os-release && echo "$${UBUNTU_CODENAME:-$VERSION_CODENAME}")
  Components: stable
  Architectures: $(dpkg --print-architecture)
  Signed-By: /etc/apt/keyrings/docker.asc
  DOCKER_SOURCES

  sudo apt-get update

  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  sudo systemctl enable docker
  sudo systemctl start docker
  echo "=================================================="

  echo "=============== 2. Install OCI CLI ==============="
  bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)" -s --accept-all-defaults \
    --install-dir /usr/local/oci-cli --exec-dir /usr/local/bin
  export OCI_CLI_AUTH=instance_principal
  oci --version
  echo "=================================================="

  echo "================ 3. Login to GHCR ================"
  set +x
  GH_USERNAME=$(oci secrets secret-bundle get --secret-id "${oci_vault_secret.github_username.id}" \
  --query 'data."secret-bundle-content".content' --raw-output | base64 -d)
  GH_TOKEN=$(oci secrets secret-bundle get --secret-id "${oci_vault_secret.github_access_token.id}" \
  --query 'data."secret-bundle-content".content' --raw-output | base64 -d)
  echo "$GH_TOKEN" | docker login ghcr.io -u "$GH_USERNAME" --password-stdin
  set -x
  echo "=================================================="

  echo "============== 4. Make Directories ==============="
  mkdir /opt/${var.prefix}
  mkdir /opt/${var.prefix}/dump
  echo "=================================================="

  echo "======= 5. Get Assets From Object Storage ========"
  cd /opt/${var.prefix}
  for KEY in ${join(" ", local.bucket_asset_keys)}; do
    oci os object get -ns "${data.oci_objectstorage_namespace.ns.namespace}" -bn "${data.oci_objectstorage_bucket.asset.name}" --name "$KEY" --file "$KEY"
  done

  for KEY in ${join(" ", local.bucket_dump_keys)}; do
    oci os object get -ns "${data.oci_objectstorage_namespace.ns.namespace}" -bn "${data.oci_objectstorage_bucket.asset.name}" --name "dump/$KEY" --file "dump/$KEY"
  done
  echo "=================================================="

  echo "======== 6. Docker Compose & Restore Data ========"
  cd /opt/${var.prefix}

  docker compose up -d --wait postgres

  docker compose create prometheus
  docker run --rm -v ${var.prefix}_promdata:/data -v "$PWD/dump":/backup alpine sh -c "rm -rf /data/* && tar xzf /backup/prometheus.tgz -C /data"

  docker exec trading-db psql -U trading -d trading -c "CREATE EXTENSION IF NOT EXISTS timescaledb;" -c "SELECT timescaledb_pre_restore();"
  RESTORE_STATUS=0
  docker exec -i trading-db pg_restore -U trading -d trading --no-owner < dump/trading.dump 2> restore_errors.log || RESTORE_STATUS=$?
  docker exec trading-db psql -U trading -d trading -c "SELECT timescaledb_post_restore();" -c "ANALYZE;"
  if [ "$RESTORE_STATUS" -ne 0 ]; then echo "RESTORE_HAD_ERRORS: /opt/${var.prefix}/restore_errors.log 확인"; cat restore_errors.log; fi

  docker compose up -d
  echo "=================================================="

  echo "BOOTSTRAP DONE"
  EOF
}

resource "oci_core_instance" "instance_1" {
  compartment_id      = var.tenancy_ocid
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  display_name        = "${var.prefix}-instance-1"
  shape               = "VM.Standard.A1.Flex"

  shape_config {
    ocpus         = 2
    memory_in_gbs = 12
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu.images[0].id
    boot_volume_size_in_gbs = 100
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.subnet_1.id
    nsg_ids          = [oci_core_network_security_group.nsg_1.id]
    assign_public_ip = false
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data = base64encode(<<-EOF
    ${local.bootstrap}
    hostnamectl set-hostname instance-1
    EOF
    )
  }

  depends_on = [
    oci_identity_policy.policy_1,
    oci_core_network_security_group_security_rule.egress_1,
  ]

  freeform_tags = {
    Team = var.team_tag
  }
}

data "oci_core_private_ips" "private_ip_1" {
  subnet_id  = oci_core_subnet.subnet_1.id
  ip_address = oci_core_instance.instance_1.private_ip
}

data "oci_core_public_ips" "public_ip_1" {
  compartment_id = var.tenancy_ocid
  scope          = "REGION"
  lifetime       = "RESERVED"

  filter {
    name   = "display_name"
    values = ["${var.prefix}-public-ip-1"]
  }
}

resource "terraform_data" "public_ip_1_attach" {
  triggers_replace = [
    data.oci_core_private_ips.private_ip_1.private_ips[0].id,
    data.oci_core_public_ips.public_ip_1.public_ips[0].id,
  ]

  provisioner "local-exec" {
    command = "oci network public-ip update --region ${var.region} --public-ip-id ${data.oci_core_public_ips.public_ip_1.public_ips[0].id} --private-ip-id ${data.oci_core_private_ips.private_ip_1.private_ips[0].id}"
  }
}
