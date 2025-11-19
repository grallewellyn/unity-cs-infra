# REST API Gateway
resource "aws_api_gateway_rest_api" "rest_api" {
  name        = "unity-${var.project}-${var.venue}-rest-api-gateway"
  description = "Unity ${var.project}-${var.venue} Project REST API Gateway"
  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

# REST API Gateway root level OPTIONS method (to allow deployment with at least one method)
resource "aws_api_gateway_method" "root_level_options_method" {
  rest_api_id   = aws_api_gateway_rest_api.rest_api.id
  resource_id   = aws_api_gateway_rest_api.rest_api.root_resource_id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

# REST API Gateway root level GET method mock integration
resource "aws_api_gateway_integration" "root_level_get_method_mock_integration" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  resource_id = aws_api_gateway_rest_api.rest_api.root_resource_id
  http_method = aws_api_gateway_method.root_level_options_method.http_method
  type        = "MOCK"
}

# REST API ID SSM Param for other resources to modify rest api
resource "aws_ssm_parameter" "api_gateway_rest_api_id_parameter" {
  name       = format("/unity/cs/routing/api-gateway/rest-api-id-2")
  type       = "String"
  overwrite  = true
  value      = aws_api_gateway_rest_api.rest_api.id
  depends_on = [aws_api_gateway_rest_api.rest_api]
}

# Download the Unity CS Common Auth Lambda deployment zip file
resource "null_resource" "download_lambda_zip" {
  provisioner "local-exec" {
    command = "wget --no-check-certificate ${var.unity_cs_lambda_authorizer_zip_path}  -O ucs-common-lambda-auth.zip"
  }
}

# CloudWatch Log Group for Unity CS Common Auth Lambda
resource "aws_cloudwatch_log_group" "cs_common_lambda_auth_log_group" {
  name              = "/aws/lambda/${var.project}-${var.venue}-${var.unity_cs_lambda_authorizer_function_name}"
  retention_in_days = 14
}

resource "aws_ssm_parameter" "invoke_role_arn" {
  name      = var.ssm_param_api_gateway_cs_lambda_authorizer_invoke_role_arn
  overwrite = true
  type      = "String"
  value     = aws_iam_role.iam_for_lambda_auth.arn
}

# Unity shared services account id
data "aws_ssm_parameter" "shared_service_account_id" {
  name = var.ssm_account_id
}

# Unity shared services account region
data "aws_ssm_parameter" "shared_service_region" {
  name = var.ssm_region
}

# Unity CS Common Lambda Authorizer Allowed Cognito User Pool ID
data "aws_ssm_parameter" "api_gateway_cs_lambda_authorizer_cognito_user_pool_id" {
  name = "arn:aws:ssm:${data.aws_ssm_parameter.shared_service_region.value}:${data.aws_ssm_parameter.shared_service_account_id.value}:parameter/unity/shared-services/cognito/user-pool-id"
}

# Unity CS Common Lambda Authorizer Allowed Cognito User Groups List (Comma Seperated)
data "aws_ssm_parameter" "api_gateway_cs_lambda_authorizer_cognito_user_groups_list" {
  name = "arn:aws:ssm:${data.aws_ssm_parameter.shared_service_region.value}:${data.aws_ssm_parameter.shared_service_account_id.value}:parameter/unity/shared-services/cognito/default-user-groups"
}

# Unity Management Console NLB
data "aws_lb" "unity_mc_nlb" {
  name = format("%s-%s-%s", var.unity_mc_nlb_name_prefix, var.project, var.venue)

  tags = {
    "Proj"  = var.project
    "Venue" = var.venue
  }
}

# IAM Policy Document for Assume Role
data "aws_iam_policy_document" "assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com", "apigateway.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

# IAM Policy Document for Inline Policy
data "aws_iam_policy_document" "inline_policy" {
  statement {
    actions = ["logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    "lambda:InvokeFunction"]
    resources = ["*"]
  }
}

# The Policy for Permission Boundary
data "aws_iam_policy" "smce_operator_policy" {
  name = "zsmce-tenantOperator-AMI-APIG"
}

# IAM Role for Lambda Authorizer
resource "aws_iam_role" "iam_for_lambda_auth" {
  name = "${var.project}-${var.venue}-iam_for_lambda_auth"
  inline_policy {
    name   = "unity-cs-lambda-auth-inline-policy"
    policy = data.aws_iam_policy_document.inline_policy.json
  }
  assume_role_policy   = data.aws_iam_policy_document.assume_role.json
  permissions_boundary = data.aws_iam_policy.smce_operator_policy.arn
}

# Unity CS Common Auth Lambda
resource "aws_lambda_function" "cs_common_lambda_auth" {
  filename      = "ucs-common-lambda-auth.zip"
  function_name = "${var.project}-${var.venue}-${var.unity_cs_lambda_authorizer_function_name}"
  role          = aws_iam_role.iam_for_lambda_auth.arn
  handler       = "index.handler"
  runtime       = "nodejs20.x"
  depends_on    = [null_resource.download_lambda_zip]

  environment {
    variables = {
      COGNITO_CLIENT_ID_LIST = "deprecated"
      COGNITO_USER_POOL_ID   = data.aws_ssm_parameter.api_gateway_cs_lambda_authorizer_cognito_user_pool_id.value
      COGNITO_GROUPS_ALLOWED = data.aws_ssm_parameter.api_gateway_cs_lambda_authorizer_cognito_user_groups_list.value
    }
  }
}

# Unity CS Common Auth Lambda Authorizer (in API Gateway)
resource "aws_api_gateway_authorizer" "unity_cs_common_authorizer" {
  name                             = "Unity_CS_Common_Authorizer"
  rest_api_id                      = aws_api_gateway_rest_api.rest_api.id
  authorizer_uri                   = aws_lambda_function.cs_common_lambda_auth.invoke_arn
  authorizer_credentials           = aws_iam_role.iam_for_lambda_auth.arn
  authorizer_result_ttl_in_seconds = 0
  identity_source                  = "method.request.header.Authorization"
  depends_on                       = [aws_lambda_function.cs_common_lambda_auth, aws_api_gateway_rest_api.rest_api]
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# API Gateway deployment
resource "aws_api_gateway_deployment" "api-gateway-deployment" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  stage_name  = var.rest_api_stage
  depends_on  = [aws_api_gateway_integration.rest_api_integration_for_health_check]
}

resource "aws_ssm_parameter" "api_gateway_uri" {
  name      = "/unity/cs/management/api-gateway/gateway-uri"
  overwrite = true
  type      = "String"
  value     = "https://${aws_api_gateway_rest_api.rest_api.id}.execute-api.${data.aws_ssm_parameter.shared_service_region.value}.amazonaws.com/${aws_api_gateway_stage.api_gateway_stage.stage_name}"
}

# Management Console Health Check API Integration Code
resource "aws_api_gateway_resource" "rest_api_resource_management_path" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  parent_id   = aws_api_gateway_rest_api.rest_api.root_resource_id
  path_part   = "management"
}

resource "aws_api_gateway_resource" "rest_api_resource_api_path" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  parent_id   = aws_api_gateway_resource.rest_api_resource_management_path.id
  path_part   = "api"
}

resource "aws_api_gateway_resource" "rest_api_resource_health_checks_path" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  parent_id   = aws_api_gateway_resource.rest_api_resource_api_path.id
  path_part   = "health_checks"
}

resource "aws_api_gateway_method" "rest_api_method_for_health_check_method" {
  rest_api_id   = aws_api_gateway_rest_api.rest_api.id
  resource_id   = aws_api_gateway_resource.rest_api_resource_health_checks_path.id
  http_method   = "GET"
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.unity_cs_common_authorizer.id
}

resource "aws_api_gateway_vpc_link" "rest_api_health_check_vpc_link" {
  name        = "mc-nlb-vpc-link-${var.project}-${var.venue}"
  description = "mc-nlb-vpc-link-${var.project}-${var.venue}"
  target_arns = [data.aws_lb.unity_mc_nlb.arn]
}

resource "aws_api_gateway_integration" "rest_api_integration_for_health_check" {
  rest_api_id             = aws_api_gateway_rest_api.rest_api.id
  resource_id             = aws_api_gateway_resource.rest_api_resource_health_checks_path.id
  http_method             = aws_api_gateway_method.rest_api_method_for_health_check_method.http_method
  type                    = "HTTP"
  uri                     = format("%s://%s:%s", "http", data.aws_lb.unity_mc_nlb.dns_name, "8080/api/health_checks")
  integration_http_method = "GET"
  passthrough_behavior    = "WHEN_NO_TEMPLATES"
  content_handling        = "CONVERT_TO_TEXT"
  connection_type         = "VPC_LINK"
  connection_id           = aws_api_gateway_vpc_link.rest_api_health_check_vpc_link.id

  depends_on              = [aws_api_gateway_vpc_link.rest_api_health_check_vpc_link]
}

resource "aws_api_gateway_method_response" "response_200" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  resource_id = aws_api_gateway_resource.rest_api_resource_health_checks_path.id
  http_method = aws_api_gateway_method.rest_api_method_for_health_check_method.http_method
  status_code = "200"

  depends_on = [aws_api_gateway_integration.rest_api_integration_for_health_check]
}

resource "aws_api_gateway_integration_response" "api_gateway_integration_response" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  resource_id = aws_api_gateway_resource.rest_api_resource_health_checks_path.id
  http_method = aws_api_gateway_method.rest_api_method_for_health_check_method.http_method
  status_code = aws_api_gateway_method_response.response_200.status_code

  depends_on = [aws_api_gateway_integration.rest_api_integration_for_health_check]
}

resource "aws_api_gateway_stage" "api_gateway_stage" {
  deployment_id = aws_api_gateway_deployment.api-gateway-deployment.id
  rest_api_id   = aws_api_gateway_rest_api.rest_api.id
  stage_name    = "default"

  depends_on = [aws_api_gateway_integration.rest_api_integration_for_health_check]
}

output "unity_venue_level_api_gateway_rest_api_id" {
  value = aws_api_gateway_rest_api.rest_api.id
}
