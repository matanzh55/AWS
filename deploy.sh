#!/bin/bash

# Variables
vpc_id="vpc-04c2582f68f0eed8f"
subnet1_id="subnet-074a977b19ae594aa"
subnet2_id="subnet-05da18daf347616b2"
ami_id="ami-0c7217cdde317cfec"  # Ubuntu AMI ID
alb_name="MyALB"
tg_red_name="TargetGroupRed"
tg_blue_name="TargetGroupBlue"

# 1. Security Group
security_group=$(aws ec2 create-security-group \
  --group-name MyWebSecurityGroup \
  --description "Security group for my EC2 instances" \
  --vpc-id $vpc_id \
  --output json \
  --query 'GroupId' \
  --output text)  # Use --output text to get plain text output without quotes

echo "Security Group ID: $security_group"

# Allow inbound traffic on port 80 (HTTP)
aws ec2 authorize-security-group-ingress \
  --group-id $security_group \
  --protocol tcp \
  --port 80 \
  --cidr 0.0.0.0/0

# 2. Load Balancer
alb_arn=$(aws elbv2 create-load-balancer \
  --name $alb_name \
  --subnets $subnet1_id $subnet2_id \
  --security-groups $security_group \
  --scheme internet-facing \
  --output json \
  --query 'LoadBalancers[0].LoadBalancerArn')

# 3. Target Groups
tg_red_arn=$(aws elbv2 create-target-group \
  --name $tg_red_name \
  --protocol HTTP \
  --port 80 \
  --vpc-id $vpc_id \
  --target-type instance \
  --output json \
  --query 'TargetGroups[0].TargetGroupArn')

tg_blue_arn=$(aws elbv2 create-target-group \
  --name $tg_blue_name \
  --protocol HTTP \
  --port 80 \
  --vpc-id $vpc_id \
  --target-type instance \
  --output json \
  --query 'TargetGroups[0].TargetGroupArn')

# 4. EC2 Instances
instance_red_id=$(aws ec2 run-instances \
  --image-id $ami_id \
  --instance-type t2.micro \
  --subnet-id $subnet1_id \
  --security-group-ids $security_group \
  --user-data "#!/bin/bash
              apt-get update
              apt-get install -y apache2
              echo '<html><head><title>Color: Red</title></head><body><h1>This is the /red instance</h1></body></html>' > /var/www/html/index.html" \
  --output json \
  --query 'Instances[0].InstanceId' | tr -d '"')

instance_blue_id=$(aws ec2 run-instances \
  --image-id $ami_id \
  --instance-type t2.micro \
  --subnet-id $subnet2_id \
  --security-group-ids $security_group \
  --user-data "#!/bin/bash
              apt-get update
              apt-get install -y apache2
              echo '<html><head><title>Color: Blue</title></head><body><h1>This is the /blue instance</h1></body></html>' > /var/www/html/index.html" \
  --output json \
  --query 'Instances[0].InstanceId' | tr -d '"')

aws ec2 wait instance-running --instance-ids $instance_red_id $instance_blue_id

# 5. Register Targets
aws elbv2 register-targets \
  --target-group-arn $(echo $tg_red_arn | sed 's/"//g') \
  --targets Id=$instance_red_id

aws elbv2 register-targets \
  --target-group-arn $(echo $tg_blue_arn | sed 's/"//g') \
  --targets Id=$instance_blue_id

# 6. Listener with Rules
listener_arn=$(aws elbv2 create-listener \
  --load-balancer-name "MyALB" \
  --protocol HTTP \
  --port 80 \
  --default-actions Type=forward,TargetGroupArn="$tg_red_arn" \
  --output json \
  --query 'Listeners[0].ListenerArn')

# Create Rule for default action (fixed response)
aws elbv2 create-rule \
  --listener-arn "$listener_arn" \
  --priority 1 \
  --conditions Field=path-pattern,Values='*' \
  --actions Type=fixed-response,FixedResponseConfig.StatusCode=200,FixedResponseConfig.ContentType=text/plain,FixedResponseConfig.Content=OK

# Create Rule for /red path
aws elbv2 create-rule \
  --listener-arn "$listener_arn" \
  --priority 2 \
  --conditions Field=path-pattern,Values='/red*' \
  --actions Type=forward,TargetGroupArn="$tg_red_arn"

# Create Rule for /blue path
aws elbv2 create-rule \
  --listener-arn "$listener_arn" \
  --priority 3 \
  --conditions Field=path-pattern,Values='/blue*' \
  --actions Type=forward,TargetGroupArn="$tg_blue_arn"

# Output results
echo "ALB ARN: $alb_arn"
echo "Target Group (Red) ARN: $tg_red_arn"
echo "Target Group (Blue) ARN: $tg_blue_arn"
echo "Listener ARN: $listener_arn"
