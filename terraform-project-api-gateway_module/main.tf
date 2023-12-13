# REST API Gateway
resource "aws_api_gateway_rest_api" "rest_api" {
  name        = var.rest_api_name
  description = var.rest_api_description
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

# REST API Gateway rot level GET method mock integration
resource "aws_api_gateway_integration" "root_level_get_method_mock_integration" {
  rest_api_id          = aws_api_gateway_rest_api.rest_api.id
  resource_id          = aws_api_gateway_rest_api.rest_api.root_resource_id
  http_method          = aws_api_gateway_method.root_level_options_method.http_method
  type                 = "MOCK"
}

# REST API ID SSM Param for other resources to modify rest api
resource "aws_ssm_parameter" "api_gateway_rest_api_id_parameter" {
  name       = format("/unity/cs/routing/api-gateway/rest-api-id-2")
  type       = "String"
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
  name              = "/aws/lambda/${var.unity_cs_lambda_authorizer_function_name}"
  retention_in_days = 14
}

# Unity CS Common Lambda Authorizer Execution Role ARN
data "aws_ssm_parameter" "api_gateway_cs_lambda_authorizer_invoke_role_arn" {
  name = var.ssm_param_api_gateway_cs_lambda_authorizer_invoke_role_arn
}

# Unity CS Common Lambda Authorizer Allowed Cognito Client ID List (Command Seperated)
data "aws_ssm_parameter" "api_gateway_cs_lambda_authorizer_cognito_client_id_list" {
  name = var.ssm_param_api_gateway_cs_lambda_authorizer_cognito_client_id_list
}

# Unity CS Common Lambda Authorizer Allowed Cognito User Pool ID
data "aws_ssm_parameter" "api_gateway_cs_lambda_authorizer_cognito_user_pool_id" {
  name = var.ssm_param_api_gateway_cs_lambda_authorizer_cognito_user_pool_id
}

# Unity CS Common Lambda Authorizer Allowed Cognito User Groups List (Command Seperated)
data "aws_ssm_parameter" "api_gateway_cs_lambda_authorizer_cognito_user_groups_list" {
  name = var.ssm_param_api_gateway_cs_lambda_authorizer_cognito_user_groups_list
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "iam_for_lambda" {
  name               = "iam_for_lambda"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

# Unity CS Common Auth Lambda
resource "aws_lambda_function" "cs_common_lambda_auth" {
  filename      = "ucs-common-lambda-auth.zip"
  function_name = var.unity_cs_lambda_authorizer_function_name
  role          = aws_iam_role.iam_for_lambda.arn
  handler       = "index.handler"
  runtime       = "nodejs14.x"
  depends_on = [null_resource.download_lambda_zip]

  environment {
    variables = {
      COGNITO_CLIENT_ID_LIST = data.aws_ssm_parameter.api_gateway_cs_lambda_authorizer_cognito_client_id_list.value
      COGNITO_USER_POOL_ID = data.aws_ssm_parameter.api_gateway_cs_lambda_authorizer_cognito_user_pool_id.value
      COGNITO_GROUPS_ALLOWED = data.aws_ssm_parameter.api_gateway_cs_lambda_authorizer_cognito_user_groups_list.value
    }
  }
}

# Unity CS Common Auth Lambda Authorizer (in API Gateway)
resource "aws_api_gateway_authorizer" "unity_cs_common_authorizer" {
  name                              = "Unity_CS_Common_Authorizer"
  rest_api_id                       = aws_api_gateway_rest_api.rest_api.id
  authorizer_uri                    = aws_lambda_function.cs_common_lambda_auth.invoke_arn
  authorizer_credentials            = aws_iam_role.iam_for_lambda.arn
  authorizer_result_ttl_in_seconds  = 0
  identity_source                   = "method.request.header.Authorization"
depends_on = [aws_lambda_function.cs_common_lambda_auth, aws_api_gateway_rest_api.rest_api]
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# API Gateway deployment
resource "aws_api_gateway_deployment" "api-gateway-deployment" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  stage_name  = var.rest_api_stage
  depends_on = [aws_api_gateway_integration.root_level_get_method_mock_integration]
}
