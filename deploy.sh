#!/bin/sh

# Based on:
# https://coder.com/docs/coder-oss/latest/install/kubernetes
# https://coder.com/docs/coder/latest/setup/kubernetes/aws

# Create the cluster but exclude nodegroups for now.
eksctl create cluster \
    --config-file cluster.yml \
    --without-nodegroup \
    --install-nvidia-plugin=false \
    --auto-kubeconfig
export KUBECONFIG="$HOME/.kube/eksctl/clusters/coder"

# Discover the availability zones where eksctl created a NAT gateway.
vpc_id=$(aws eks describe-cluster \
    --name "coder" \
    --query 'cluster.resourcesVpcConfig.vpcId' \
    --output text)
public_subnet_ids_commasep=$(aws ec2 describe-nat-gateways \
    --filter "Name=vpc-id,Values=$vpc_id" "Name=tag:alpha.eksctl.io/cluster-name,Values=coder" \
    --query 'NatGateways[*].SubnetId' \
    --output json | jq -r 'join(",")')
public_azs=$(aws ec2 describe-subnets \
    --filters "Name=subnet-id,Values=$public_subnet_ids_commasep" \
    --query 'Subnets[*].AvailabilityZone' \
    --output json)

# Add the nodegroups and configure the workspace groups to scale up only in the
# availability zones with a NAT gateway. This ensures that traffic between
# nodes, EFS mount targets and RDS stays within the same availability zone.
eksctl create nodegroup --config-file cluster.yml

# Update the default add-ons.
eksctl utils update-kube-proxy --cluster=coder --approve
eksctl utils update-aws-node --cluster=coder --approve
eksctl utils update-coredns --cluster=coder --approve

# Install Calico.
helm repo add projectcalico https://docs.projectcalico.org/charts \
    && helm repo update
helm upgrade calico projectcalico/tigera-operator \
    --atomic \
    --cleanup-on-fail \
    --create-namespace \
    --install \
    --namespace tigera-operator \
    --reset-values \
    --set installation.kubernetesProvider=EKS

# Create the Route53 hosted zone.
route53_caller_ref=$(cat /proc/sys/kernel/random/uuid)
aws route53 create-hosted-zone \
    --name "code.ikim.uk-essen.de." \
    --caller-reference $route53_caller_ref \
    --hosted-zone-config Comment="coder-zone"

hosted_zone_id="$(aws route53 list-hosted-zones-by-name \
    --dns-name "code.ikim.uk-essen.de." \
    --query "HostedZones[0].Id" \
    --output json \
    --out text)"

# Deploy ExternalDNS.
helm repo add bitnami https://charts.bitnami.com/bitnami \
    && helm repo update
helm upgrade external-dns bitnami/external-dns \
    --atomic \
    --cleanup-on-fail \
    --create-namespace \
    --install \
    --namespace external-dns \
    --reset-values \
    --wait \
    --values helm-values/external-dns.yml

# Install the EFS CSI driver.
helm repo add aws-efs-csi-driver https://kubernetes-sigs.github.io/aws-efs-csi-driver/ \
    && helm repo update
helm upgrade aws-efs-csi-driver aws-efs-csi-driver/aws-efs-csi-driver \
    --atomic \
    --cleanup-on-fail \
    --create-namespace \
    --install \
    --namespace kube-system \
    --reset-values \
    --values helm-values/aws-efs-csi-driver.yml

# Deploy the Cluster Autoscaler
helm repo add autoscaler https://kubernetes.github.io/autoscaler \
    && helm repo update
helm upgrade autoscaler autoscaler/cluster-autoscaler \
    --atomic \
    --cleanup-on-fail \
    --install \
    --namespace kube-system \
    --reset-values \
    --wait \
    -f helm-values/autoscaler.yml

# Create the main namespace.
kubectl create namespace coder

# Create a custom security group for Coder pods.
kubectl set env daemonset -n kube-system aws-node ENABLE_POD_ENI=true
kubectl set env daemonset -n kube-system aws-node POD_SECURITY_GROUP_ENFORCING_MODE=standard
cluster_security_group_id=$(aws eks describe-cluster \
    --name "coder" \
    --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' \
    --output text)
aws ec2 create-security-group \
    --group-name coder-pods \
    --description 'Coder pods' \
    --vpc-id $vpc_id
coder_pod_security_group_id=$(aws ec2 describe-security-groups \
    --filters Name=group-name,Values=coder-pods Name=vpc-id,Values=$vpc_id \
    --query 'SecurityGroups[*].[GroupId]' \
    --output text)
kubectl apply -f manifests/security-group-policy.yml

# Create a security group for NFS mounts.
cidr_range=$(aws ec2 describe-vpcs \
    --vpc-ids $vpc_id \
    --query 'Vpcs[].CidrBlock' \
    --output text)
aws ec2 create-security-group \
    --group-name coder-efs \
    --description "NFS traffic from Coder pods to the EFS instance" \
    --vpc-id $vpc_id
efs_security_group_id=$(aws ec2 describe-security-groups \
    --filters Name=group-name,Values=coder-efs Name=vpc-id,Values=$vpc_id \
    --query 'SecurityGroups[*].[GroupId]' \
    --output text)
aws ec2 authorize-security-group-ingress \
    --group-id $efs_security_group_id \
    --cidr $cidr_range \
    --protocol tcp \
    --port 2049

# Create an EFS file system.
aws efs create-file-system \
    --region eu-central-1 \
    --performance-mode generalPurpose
file_system_id=$(aws efs describe-file-systems \
    --region eu-central-1 \
    --query 'FileSystems[*].[FileSystemId]' \
    --output text)

# Create a mount target in each availability zone with a NAT gateway.
public_subnet_ids=$(aws ec2 describe-nat-gateways \
    --filter "Name=vpc-id,Values=$vpc_id" "Name=tag:alpha.eksctl.io/cluster-name,Values=coder" \
    --query 'NatGateways[*].SubnetId' \
    --output text)
for subnet_id in $public_subnet_ids; do
    aws efs create-mount-target \
        --file-system-id $file_system_id \
        --subnet-id $subnet_id \
        --security-groups $efs_security_group_id
done

# Create an EFS access point for the shared dataset.
aws efs create-access-point \
    --file-system-id $file_system_id \
    --root-directory "Path=/datashare,CreationInfo={OwnerUid=1000,OwnerGid=1000,Permissions=775}" \
    --posix-user "Uid=1000,Gid=1000"
datashare_access_point=$(aws efs describe-access-points \
    --file-system-id $file_system_id \
    --query "AccessPoints[?RootDirectory.Path=='/datashare'].[AccessPointId]" \
    --output text)

# Create the resources for mounting the shared dataset on the EFS filesystem.
kubectl apply -f manifests/efs-datashareclass.yml
kubectl apply -f manifests/efs-datasharevolume.yml
kubectl apply -f manifests/efs-datashareclaim.yml

# Create the storage class for dynamic provisioning of workspace homes on the EFS filesystem.
kubectl apply -f manifests/efs-workspaceclass.yml

# Deploy the RDS instance.
public_subnet_ids_json=$(aws ec2 describe-nat-gateways \
    --filter "Name=vpc-id,Values=$vpc_id" "Name=tag:alpha.eksctl.io/cluster-name,Values=coder" \
    --query 'NatGateways[*].SubnetId' \
    --output json | jq -c '.')
aws rds create-db-subnet-group \
    --db-subnet-group-name coder-rds \
    --db-subnet-group-description "RDS deployment in Coder's VPC" \
    --subnet-ids "$public_subnet_ids_json"
aws ec2 create-security-group \
    --group-name coder-rds \
    --description "PostgreSQL traffic from Coder pods to the RDS instance" \
    --vpc-id $vpc_id
rds_security_group_id=$(aws ec2 describe-security-groups \
    --filters Name=group-name,Values=coder-rds Name=vpc-id,Values=$vpc_id \
    --query 'SecurityGroups[*].[GroupId]' \
    --output text)
aws ec2 authorize-security-group-ingress \
    --group-id $rds_security_group_id \
    --source-group $coder_pod_security_group_id \
    --protocol tcp \
    --port 5432
rds_db_name="coder"
rds_user_name="coder"
rds_user_password=$(openssl rand -hex 18)
aws rds create-db-instance \
    --db-name "$rds_db_name" \
    --db-instance-identifier coder-instance \
    --db-instance-class db.m5.large \
    --db-subnet-group-name coder-rds \
    --vpc-security-group-ids $rds_security_group_id \
    --multi-az \
    --engine postgres \
    --allocated-storage 10 \
    --max-allocated-storage 40 \
    --master-username "$rds_user_name" \
    --master-user-password "$rds_user_password"

# Create a secret containing the database URL.
rds_endpoint=$(aws rds describe-db-instances \
    --db-instance-identifier coder-instance \
    --query 'DBInstances[0].[Endpoint.Address]' \
    --output text)
kubectl create secret generic coder-db-url \
    --namespace coder \
    --from-literal=url="postgres://$rds_user_name:$rds_user_password@$rds_endpoint:5432/$rds_db_name?sslmode=disable"

# Deploy cert-manager.
helm repo add jetstack https://charts.jetstack.io \
    && helm repo update
helm upgrade cert-manager jetstack/cert-manager \
    --atomic \
    --cleanup-on-fail \
    --create-namespace \
    --install \
    --namespace cert-manager \
    --reset-values \
    --values helm-values/cert-manager.yml

# Create a ClusterIssuer resource and a Certificate resource for cert-manager.
kubectl apply -f manifests/cert-issuer.yml
kubectl apply -f manifests/cert.yml

# Deploy Reloader.
helm repo add stakater https://stakater.github.io/stakater-charts \
    && helm repo update
helm upgrade reloader stakater/reloader \
    --atomic \
    --cleanup-on-fail \
    --create-namespace \
    --install \
    --namespace reloader \
    --reset-values

# Install the Nvidia GPU Operator.
kubectl create namespace gpu-operator
kubectl create configmap nvidia-device-plugin-configmap \
    --namespace gpu-operator \
    --from-file=tworeplicas=manifests/nvidia-device-configmap-tworeplicas.yml \
    --from-file=threereplicas=manifests/nvidia-device-configmap-threereplicas.yml
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia \
    && helm repo update
helm upgrade gpu-operator nvidia/gpu-operator \
    --atomic \
    --cleanup-on-fail \
    --install \
    --namespace gpu-operator \
    --reset-values \
    --set toolkit.enabled=false \
    --set driver.enabled=false \
    --set devicePlugin.config.name=nvidia-device-plugin-configmap

# Install Coder.
helm upgrade coder https://github.com/coder/coder/releases/download/v0.12.9/coder_helm_0.12.9.tgz \
    --atomic \
    --cleanup-on-fail \
    --install \
    --namespace coder \
    --reset-values \
    --values helm-values/coder.yml

# Create a repository on Amazon ECR.
aws ecr create-repository \
    --repository-name mlcourse \
    --image-scanning-configuration scanOnPush=true \
    --region eu-central-1
repo_uri=$(aws ecr describe-repositories \
    --repository-names mlcourse \
    --query 'repositories[*].[repositoryUri]' \
    --output text)
aws ecr get-login-password --region eu-central-1 | docker login --username AWS --password-stdin "$repo_uri"

# Add a lifecycle policy to delete untagged container images.
aws ecr put-lifecycle-policy \
    --repository-name mlcourse \
    --lifecycle-policy-text "file://policies/ecr-lifecycle.json"

# Build and push the Docker image.
pushd docker
docker buildx build --platform linux/amd64 -t "$repo_uri:latest" .
docker push "$repo_uri:latest"
popd

# Install the Coder templates.
# coder login https://code.ikim.uk-essen.de
# coder templates create default --directory coder-templates/default
# coder templates create admin --directory coder-templates/admin

# Destroy Coder
kubectl delete namespace coder

# Destroy the cluster.
eksctl delete cluster --name "coder"
