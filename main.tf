locals {
  codestar_enabled = module.this.enabled && var.codestar_connection_arn != "" && var.codestar_connection_arn != null

  # Analysis stage (opt-in). Only supported on the CodeStar connection pipeline.
  analysis_enabled = local.codestar_enabled && var.analysis_enabled

  analysis_project_arn = local.analysis_enabled ? format(
    "arn:aws:codebuild:%s:%s:project/%s",
    var.region != "" ? var.region : data.aws_region.default.name,
    var.aws_account_id != "" ? var.aws_account_id : data.aws_caller_identity.default.account_id,
    var.analysis_project_name
  ) : ""

  # Namespace of the Source action output variables (BranchName, CommitId, ...).
  # Only set when the analysis stage is enabled, so existing pipelines are unaffected.
  source_namespace = local.analysis_enabled ? "SourceVariables" : null

  # Variables always injected into the analysis action. The branch/commit come from
  # the push that triggered the execution (works with fixed branches and release/* triggers).
  analysis_default_environment_variables = [
    { name = "PIPELINE_NAME", value = module.codepipeline_label.id, type = "PLAINTEXT" },
    { name = "PIPELINE_EXECUTION_ID", value = "#{codepipeline.PipelineExecutionId}", type = "PLAINTEXT" },
    { name = "REPO_NAME", value = var.repo_name, type = "PLAINTEXT" },
    { name = "BRANCH_NAME", value = "#{SourceVariables.BranchName}", type = "PLAINTEXT" },
    { name = "COMMIT_ID", value = "#{SourceVariables.CommitId}", type = "PLAINTEXT" },
  ]

  analysis_environment_variables = concat(
    local.analysis_default_environment_variables,
    var.analysis_environment_variables
  )
}

module "codepipeline_label" {
  source     = "cloudposse/label/null"
  version    = "0.25.0"
  attributes = ["codepipeline"]

  context = module.this.context
}

resource "aws_s3_bucket" "default" {
  count         = module.this.enabled ? 1 : 0
  bucket        = module.codepipeline_label.id
  acl           = "private"
  force_destroy = var.s3_bucket_force_destroy
  tags          = module.codepipeline_label.tags
}

module "codepipeline_assume_role_label" {
  source     = "cloudposse/label/null"
  version    = "0.25.0"
  attributes = ["codepipeline", "assume"]

  context = module.this.context
}

resource "aws_iam_role" "default" {
  count              = module.this.enabled ? 1 : 0
  name               = module.codepipeline_assume_role_label.id
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    sid = ""

    actions = [
      "sts:AssumeRole"
    ]

    principals {
      type        = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }

    effect = "Allow"
  }
}

resource "aws_iam_role_policy_attachment" "default" {
  count      = module.this.enabled ? 1 : 0
  role       = join("", aws_iam_role.default.*.id)
  policy_arn = join("", aws_iam_policy.default.*.arn)
}

resource "aws_iam_policy" "default" {
  count  = module.this.enabled ? 1 : 0
  name   = module.codepipeline_label.id
  policy = data.aws_iam_policy_document.default.json
}

data "aws_iam_policy_document" "default" {
  statement {
    sid = ""

    actions = [
      "ec2:*",
      "elasticloadbalancing:*",
      "autoscaling:*",
      "cloudwatch:*",
      "s3:*",
      "sns:*",
      "cloudformation:*",
      "rds:*",
      "sqs:*",
      "ecs:*",
      "iam:PassRole"
    ]

    resources = ["*"]
    effect    = "Allow"
  }
}

resource "aws_iam_role_policy_attachment" "s3" {
  count      = module.this.enabled ? 1 : 0
  role       = join("", aws_iam_role.default.*.id)
  policy_arn = join("", aws_iam_policy.s3.*.arn)
}

module "codepipeline_s3_policy_label" {
  source     = "cloudposse/label/null"
  version    = "0.25.0"
  attributes = ["codepipeline", "s3"]

  context = module.this.context
}

resource "aws_iam_policy" "s3" {
  count  = module.this.enabled ? 1 : 0
  name   = module.codepipeline_s3_policy_label.id
  policy = join("", data.aws_iam_policy_document.s3.*.json)
}

data "aws_iam_policy_document" "s3" {
  count = module.this.enabled ? 1 : 0

  statement {
    sid = ""

    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:GetBucketVersioning",
      "s3:PutObject"
    ]

    resources = [
      join("", aws_s3_bucket.default.*.arn),
      "${join("", aws_s3_bucket.default.*.arn)}/*"
    ]

    effect = "Allow"
  }
}

resource "aws_iam_role_policy_attachment" "codebuild" {
  count      = module.this.enabled ? 1 : 0
  role       = join("", aws_iam_role.default.*.id)
  policy_arn = join("", aws_iam_policy.codebuild.*.arn)
}

module "codebuild_label" {
  source     = "cloudposse/label/null"
  version    = "0.25.0"
  attributes = ["codebuild"]

  context = module.this.context
}

resource "aws_iam_policy" "codebuild" {
  count  = module.this.enabled ? 1 : 0
  name   = module.codebuild_label.id
  policy = data.aws_iam_policy_document.codebuild.json
}

data "aws_iam_policy_document" "codebuild" {
  statement {
    sid = ""

    actions = [
      "codebuild:*"
    ]

    # The analysis project (if any) is invoked by the same pipeline role.
    resources = compact([module.codebuild.project_id, local.analysis_project_arn])
    effect    = "Allow"
  }
}

# https://docs.aws.amazon.com/codepipeline/latest/userguide/connections-permissions.html
resource "aws_iam_role_policy_attachment" "codestar" {
  count      = local.codestar_enabled ? 1 : 0
  role       = join("", aws_iam_role.default.*.id)
  policy_arn = join("", aws_iam_policy.codestar.*.arn)
}

module "codestar_label" {
  source     = "cloudposse/label/null"
  version    = "0.25.0"
  enabled    = local.codestar_enabled
  attributes = ["codestar"]

  context = module.this.context
}

resource "aws_iam_policy" "codestar" {
  count  = local.codestar_enabled ? 1 : 0
  name   = module.codestar_label.id
  policy = join("", data.aws_iam_policy_document.codestar.*.json)
}

data "aws_iam_policy_document" "codestar" {
  count = local.codestar_enabled ? 1 : 0
  statement {
    sid = ""

    actions = [
      "codestar-connections:UseConnection"
    ]

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "codestar-connections:FullRepositoryId"
      values = [
        format("%s/%s", var.repo_owner, var.repo_name)
      ]
    }

    resources = [var.codestar_connection_arn]
    effect    = "Allow"

  }
}

data "aws_caller_identity" "default" {
}

data "aws_region" "default" {
}

module "codebuild" {
  enabled                               = module.this.enabled
  source                                = "cloudposse/codebuild/aws"
  version                               = "2.0.2"
  build_type                            = var.build_type
  build_image                           = var.build_image
  build_compute_type                    = var.build_compute_type
  build_timeout                         = var.build_timeout
  buildspec                             = var.buildspec
  delimiter                             = module.this.delimiter
  attributes                            = ["build"]
  privileged_mode                       = var.privileged_mode
  aws_region                            = var.region != "" ? var.region : data.aws_region.default.name
  aws_account_id                        = var.aws_account_id != "" ? var.aws_account_id : data.aws_caller_identity.default.account_id
  image_repo_name                       = var.image_repo_name
  image_tag                             = var.image_tag
  github_token                          = var.github_oauth_token
  environment_variables                 = var.environment_variables
  badge_enabled                         = var.badge_enabled
  cache_type                            = var.cache_type
  local_cache_modes                     = var.local_cache_modes
  secondary_artifact_location           = var.secondary_artifact_bucket_id
  secondary_artifact_identifier         = var.secondary_artifact_identifier
  secondary_artifact_encryption_enabled = var.secondary_artifact_encryption_enabled
  vpc_config                            = var.codebuild_vpc_config
  cache_bucket_suffix_enabled           = var.cache_bucket_suffix_enabled

  context = module.this.context
}

resource "aws_iam_role_policy_attachment" "codebuild_s3" {
  count      = module.this.enabled ? 1 : 0
  role       = module.codebuild.role_id
  policy_arn = join("", aws_iam_policy.s3.*.arn)
}

resource "aws_iam_role_policy_attachment" "codebuild_codestar" {
  count      = local.codestar_enabled && var.codestar_output_artifact_format == "CODEBUILD_CLONE_REF" ? 1 : 0
  role       = module.codebuild.role_id
  policy_arn = join("", aws_iam_policy.codestar.*.arn)
}

resource "aws_iam_role_policy_attachment" "codebuild_extras" {
  for_each   = module.this.enabled ? toset(var.codebuild_extra_policy_arns) : []
  role       = module.codebuild.role_id
  policy_arn = each.value
}

resource "aws_codepipeline" "default" {
  count          = module.this.enabled && var.github_oauth_token != "" ? 1 : 0
  name           = module.codepipeline_label.id
  role_arn       = join("", aws_iam_role.default.*.arn)
  pipeline_type  = var.pipeline_type
  execution_mode = var.execution_mode

  artifact_store {
    location = join("", aws_s3_bucket.default.*.bucket)
    type     = "S3"
  }

  depends_on = [
    aws_iam_role_policy_attachment.default,
    aws_iam_role_policy_attachment.s3,
    aws_iam_role_policy_attachment.codebuild,
    aws_iam_role_policy_attachment.codebuild_s3,
    aws_iam_role_policy_attachment.codebuild_extras
  ]

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "ThirdParty"
      provider         = "GitHub"
      version          = "1"
      output_artifacts = ["code"]

      configuration = {
        OAuthToken           = var.github_oauth_token
        Owner                = var.repo_owner
        Repo                 = var.repo_name
        Branch               = var.branch
        PollForSourceChanges = var.poll_source_changes
      }
    }
  }

  stage {
    name = "Build"

    action {
      name     = "Build"
      category = "Build"
      owner    = "AWS"
      provider = "CodeBuild"
      version  = "1"

      input_artifacts  = ["code"]
      output_artifacts = ["task"]

      configuration = {
        ProjectName = module.codebuild.project_name
      }
    }
  }

  stage {
    name = "Deploy"

    action {
      name            = "Deploy"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "ECS"
      input_artifacts = ["task"]
      version         = "1"

      configuration = {
        ClusterName = var.ecs_cluster_name
        ServiceName = var.service_name
      }
    }
  }

  lifecycle {
    # prevent github OAuthToken from causing updates, since it's removed from state file
    ignore_changes = [stage[0].action[0].configuration]
  }
}

# https://docs.aws.amazon.com/codepipeline/latest/userguide/action-reference-CodestarConnectionSource.html#action-reference-CodestarConnectionSource-example
resource "aws_codepipeline" "bitbucket" {
  count          = local.codestar_enabled ? 1 : 0
  name           = module.codepipeline_label.id
  role_arn       = join("", aws_iam_role.default.*.arn)
  pipeline_type  = var.pipeline_type
  execution_mode = var.execution_mode

  artifact_store {
    location = join("", aws_s3_bucket.default.*.bucket)
    type     = "S3"
  }

  depends_on = [
    aws_iam_role_policy_attachment.default,
    aws_iam_role_policy_attachment.s3,
    aws_iam_role_policy_attachment.codebuild,
    aws_iam_role_policy_attachment.codebuild_s3,
    aws_iam_role_policy_attachment.codestar,
    aws_iam_role_policy_attachment.codebuild_extras
  ]

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["code"]
      namespace        = local.source_namespace

      configuration = {
        ConnectionArn        = var.codestar_connection_arn
        FullRepositoryId     = format("%s/%s", var.repo_owner, var.repo_name)
        BranchName           = var.branch
        OutputArtifactFormat = var.codestar_output_artifact_format
      }
    }
  }

  # Optional static code analysis. Runs on the same commit as the Build stage;
  # if it fails, the pipeline stops before building/deploying.
  dynamic "stage" {
    for_each = local.analysis_enabled ? [1] : []

    content {
      name = "Analysis"

      action {
        name            = "Analysis"
        category        = "Test"
        owner           = "AWS"
        provider        = "CodeBuild"
        version         = "1"
        input_artifacts = ["code"]

        configuration = {
          ProjectName          = var.analysis_project_name
          EnvironmentVariables = jsonencode(local.analysis_environment_variables)
        }
      }
    }
  }

  stage {
    name = "Build"

    action {
      name     = "Build"
      category = "Build"
      owner    = "AWS"
      provider = "CodeBuild"
      version  = "1"

      input_artifacts  = ["code"]
      output_artifacts = ["task"]

      configuration = {
        ProjectName = module.codebuild.project_name
      }
    }
  }

  stage {
    name = "Deploy"

    action {
      name            = "Deploy"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "ECS"
      input_artifacts = ["task"]
      version         = "1"

      configuration = {
        ClusterName = var.ecs_cluster_name
        ServiceName = var.service_name
      }
    }
  }

  # https://docs.aws.amazon.com/codepipeline/latest/userguide/trigger-configure-push.html
  # When configured, CodePipeline uses the branch that triggered the push instead of the
  # fixed `BranchName` set on the Source action's git_configuration above.
  dynamic "trigger" {
    for_each = var.trigger_enabled ? [1] : []

    content {
      provider_type = "CodeStarSourceConnection"

      git_configuration {
        source_action_name = "Source"

        push {
          branches {
            includes = var.trigger_branches_includes
          }
        }
      }
    }
  }

  lifecycle {
    precondition {
      condition     = !var.trigger_enabled || var.pipeline_type == "V2"
      error_message = "trigger_enabled requires pipeline_type = \"V2\". The CodePipeline `trigger` block (git push filters) is only supported on V2 pipelines."
    }

    precondition {
      condition     = !var.analysis_enabled || var.analysis_project_name != ""
      error_message = "analysis_enabled requires analysis_project_name (name of an existing CodeBuild project)."
    }

    precondition {
      condition     = !var.analysis_enabled || var.codestar_output_artifact_format == "CODEBUILD_CLONE_REF"
      error_message = "analysis_enabled requires codestar_output_artifact_format = \"CODEBUILD_CLONE_REF\" (the analysis needs the git history to compute the diff)."
    }
  }
}

resource "random_string" "webhook_secret" {
  count  = module.this.enabled && var.webhook_enabled ? 1 : 0
  length = 32

  # Special characters are not allowed in webhook secret (AWS silently ignores webhook callbacks)
  special = false
}

locals {
  webhook_secret = join("", random_string.webhook_secret.*.result)
  webhook_url    = join("", aws_codepipeline_webhook.webhook.*.url)
}

resource "aws_codepipeline_webhook" "webhook" {
  count           = module.this.enabled && var.webhook_enabled ? 1 : 0
  name            = module.codepipeline_label.id
  authentication  = var.webhook_authentication
  target_action   = var.webhook_target_action
  target_pipeline = join("", aws_codepipeline.default.*.name)

  authentication_configuration {
    secret_token = local.webhook_secret
  }

  filter {
    json_path    = var.webhook_filter_json_path
    match_equals = var.webhook_filter_match_equals
  }
}

module "github_webhooks" {
  source  = "cloudposse/repository-webhooks/github"
  version = "0.14.0"

  enabled              = module.this.enabled && var.webhook_enabled ? true : false
  github_repositories  = [var.repo_name]
  webhook_url          = local.webhook_url
  webhook_secret       = local.webhook_secret
  webhook_content_type = "json"
  events               = var.github_webhook_events

  context = module.this.context
}
