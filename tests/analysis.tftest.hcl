mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { name = "us-east-1" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111111111111" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}
mock_provider "random" {}

variables {
  name                      = "app"
  namespace                 = "merlin"
  region                    = "us-east-1"
  aws_account_id            = "111111111111"
  ecs_cluster_name          = "c"
  service_name              = "s"
  image_repo_name           = "r"
  repo_owner                = "Merlin-Data-Quality"
  repo_name                 = "node-merlin"
  branch                    = "master"
  codestar_connection_arn   = "arn:aws:codestar-connections:us-east-1:111111111111:connection/x"
  pipeline_type             = "V2"
  execution_mode            = "QUEUED"
  trigger_enabled           = true
  trigger_branches_includes = ["release/*"]
  webhook_enabled           = false
  cache_type                = "NO_CACHE"
}

run "default_unchanged" {
  command = plan
  assert {
    condition     = [for s in aws_codepipeline.bitbucket[0].stage : s.name] == ["Source", "Build", "Deploy"]
    error_message = "stages changed without analysis"
  }
  assert {
    condition     = aws_codepipeline.bitbucket[0].stage[0].action[0].namespace == null
    error_message = "namespace must be null when analysis disabled"
  }
}

run "analysis_enabled" {
  command = plan
  variables {
    codestar_output_artifact_format = "CODEBUILD_CLONE_REF"
    analysis_enabled                = true
    analysis_project_name           = "code-analysis-js"
    analysis_environment_variables  = [{ name = "ESLINT_PROFILE", value = "node", type = "PLAINTEXT" }]
  }
  assert {
    condition     = [for s in aws_codepipeline.bitbucket[0].stage : s.name] == ["Source", "Analysis", "Build", "Deploy"]
    error_message = "wrong stage order"
  }
  assert {
    condition     = aws_codepipeline.bitbucket[0].stage[0].action[0].namespace == "SourceVariables"
    error_message = "namespace missing"
  }
  assert {
    condition     = length(jsondecode(aws_codepipeline.bitbucket[0].stage[1].action[0].configuration.EnvironmentVariables)) == 6
    error_message = "env vars wrong"
  }
  assert {
    condition     = local.analysis_project_arn == "arn:aws:codebuild:us-east-1:111111111111:project/code-analysis-js"
    error_message = "arn wrong"
  }
  assert {
    condition     = length(aws_iam_role_policy_attachment.codebuild_codestar) == 1
    error_message = "codestar policy not attached to codebuild role"
  }
}

run "analysis_requires_clone_ref" {
  command = plan
  variables {
    analysis_enabled      = true
    analysis_project_name = "code-analysis-js"
  }
  expect_failures = [aws_codepipeline.bitbucket]
}

run "analysis_requires_project" {
  command = plan
  variables {
    codestar_output_artifact_format = "CODEBUILD_CLONE_REF"
    analysis_enabled                = true
  }
  expect_failures = [aws_codepipeline.bitbucket]
}
