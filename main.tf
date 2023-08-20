provider "aws" {
  region = "ap-northeast-2"

  # 2.x 버전의 AWS 공급자 허용
  version = "~> 5.7"
}

terraform {
  backend "s3" {
    bucket         = "terraform-state-interface"
    key            = "Seoul-RDS-terraform.tfstate"
    region         = "ap-northeast-2"
    # dynamodb_table = "terraform.tfstate-locking"
    encrypt        = true
  }
}

#인프라 배포 state 파일 불러오기
data "terraform_remote_state" "terraform_state" {
  backend = "s3"

  config = {
    bucket = "terraform-state-interface"
    key    = "Seoul-terraform.tfstate"
    region = "ap-northeast-2"
  }
}


#iam_role for RDS_Proxy: rds proxy 생성할 iam 역할 데이터 소스로 불러오기
data "aws_iam_role" "RDS_Proxy_iam" {
  name = "" # 본인 rds proxy iam 으로 교체
}

# Seoul Region Aurora Cluster Subnet group: 오로라 클러스터 서브넷 그룹 생성
resource "aws_db_subnet_group" "aws_aurora_subnet_group" {
  name       = "rds_cluster_group"
  subnet_ids = [data.terraform_remote_state.terraform_state.outputs.aws_subnet_priSN3_Seoul, data.terraform_remote_state.terraform_state.outputs.aws_subnet_priSN4_Seoul]
  tags = {
    Name = "Seoul Aurora subnet group"
  }
}

resource "aws_rds_cluster_parameter_group" "rds_cluster_Seoul" {
  name        = "rds-cluster-seoul"
  family      = "aurora-mysql5.7"
  description = "RDS default cluster parameter group"

  parameter {
    name  = "character_set_server"
    value = "utf8"
  }

  parameter {
    name  = "character_set_client"
    value = "utf8"
  }

  parameter {
    name  = "binlog_format"
    value = "ROW"
    apply_method = "pending-reboot"
  }  
}

# Seoul Region Aurora Cluster: 서울쪽에 오로라 클러스터 생성
resource "aws_rds_cluster" "Seoul_aurora_cluster" {
  apply_immediately       = true
  cluster_identifier      = "aurora-cluster-seoul"
  engine                  = "aurora-mysql"
  engine_version          = "5.7.mysql_aurora.2.11.3"
  db_subnet_group_name    = aws_db_subnet_group.aws_aurora_subnet_group.name
  vpc_security_group_ids = [ data.terraform_remote_state.terraform_state.outputs.aws_security_group_Aurora_Seoul ]
  database_name           = var.db_name
  master_username = "admin"
  manage_master_user_password = true
  backup_retention_period = 5
  skip_final_snapshot = true
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.rds_cluster_Seoul.name
}

# Aurora Cluster Instance 
resource "aws_rds_cluster_instance" "primary" {
  cluster_identifier    = aws_rds_cluster.Seoul_aurora_cluster.id
  identifier            = "seoul-database-2"
  engine                = "aurora-mysql"
  instance_class        = "db.t3.small"  # 원하는 인스턴스 유형으로 변경하세요.
  publicly_accessible   = false
}

resource "aws_rds_cluster_instance" "secondary" {
  cluster_identifier    = aws_rds_cluster.Seoul_aurora_cluster.id
  identifier            = "seoul-database-3"
  engine                = "aurora-mysql"
  instance_class        = "db.t3.small"  # 원하는 인스턴스 유형으로 변경하세요.
  publicly_accessible   = false
}


#RDS Proxy
resource "aws_db_proxy" "RDS_Proxy" {
  depends_on = [ aws_rds_cluster.Seoul_aurora_cluster ]
  name                   = "rds-proxy"
  debug_logging          = false
  engine_family          = "MYSQL"
  idle_client_timeout    = 1800
  require_tls            = false
  role_arn               = data.aws_iam_role.RDS_Proxy_iam.arn       
  vpc_security_group_ids = [ data.terraform_remote_state.terraform_state.outputs.aws_security_group_Aurora_Seoul ]
  vpc_subnet_ids         = aws_db_subnet_group.aws_aurora_subnet_group.subnet_ids

  auth {
    auth_scheme = "SECRETS"
    iam_auth    = "DISABLED"
    secret_arn  =  aws_rds_cluster.Seoul_aurora_cluster.master_user_secret[0]["secret_arn"]

  }

  tags = {
    Name = "Seoul-RDS-Proxy"
    Key  = "value"
  }
}

# RDS Proxy 타겟 그룹 
resource "aws_db_proxy_default_target_group" "RDS_Proxy_target_group" {
  db_proxy_name = aws_db_proxy.RDS_Proxy.name

  connection_pool_config {
    connection_borrow_timeout    = 120
    max_connections_percent      = 100
    max_idle_connections_percent = 50
    session_pinning_filters      = ["EXCLUDE_VARIABLE_SETS"]
  }
}

# RDS Proxy 타겟 
resource "aws_db_proxy_target" "RDS_Proxy_target" {
  db_cluster_identifier  = aws_rds_cluster.Seoul_aurora_cluster.cluster_identifier
  db_proxy_name          = aws_db_proxy.RDS_Proxy.name
  target_group_name      = aws_db_proxy_default_target_group.RDS_Proxy_target_group.name
}

resource "aws_db_proxy_endpoint" "read_only_EP" {
  db_proxy_name          = aws_db_proxy.RDS_Proxy.name
  db_proxy_endpoint_name = "readonly"
  vpc_subnet_ids         = aws_db_subnet_group.aws_aurora_subnet_group.subnet_ids
  vpc_security_group_ids = [ data.terraform_remote_state.terraform_state.outputs.aws_security_group_Aurora_Seoul ]
  target_role            = "READ_ONLY"
}
