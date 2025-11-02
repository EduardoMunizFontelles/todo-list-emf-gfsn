############################
# S3 para artifacts
############################
resource "aws_s3_bucket" "artifacts" {
  bucket        = "emf-gfsn-artifacts-${var.account_id}-${var.region}"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration { status = "Enabled" }
}

############################
# ECR
############################
resource "aws_ecr_repository" "app" {
  name                 = var.ecr_repo_name
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration { scan_on_push = true }
}

############################
# IAM - CodePipeline
############################
data "aws_iam_policy_document" "codepipeline_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codepipeline" {
  name               = "emf-gfsn-codepipeline-role"
  assume_role_policy = data.aws_iam_policy_document.codepipeline_trust.json
}

data "aws_iam_policy_document" "codepipeline_policy" {
  statement {
    sid      = "S3Artifacts"
    actions  = ["s3:GetObject","s3:GetObjectVersion","s3:PutObject","s3:ListBucket"]
    resources = [
      aws_s3_bucket.artifacts.arn,
      "${aws_s3_bucket.artifacts.arn}/*"
    ]
  }

  statement {
    sid      = "CodeBuild"
    actions  = ["codebuild:BatchGetBuilds","codebuild:StartBuild","codebuild:StartBuildBatch"]
    resources = ["*"]
  }

  statement {
    sid      = "CodeStarUse"
    actions  = ["codestar-connections:UseConnection"]
    resources = [var.codestar_connection_arn]
  }

  statement {
    sid     = "CodeConnectionsUse"
    actions = [
      "codeconnections:UseConnection",
      "codestar-connections:UseConnection"
    ]
    resources = [var.codestar_connection_arn]
  }

  statement {
  sid     = "CodeConnectionsRepoLink"
    actions = [
      "codeconnections:CreateRepositoryLink",
      "codeconnections:UpdateRepositoryLink",
      "codeconnections:GetRepositoryLink",
      "codeconnections:ListRepositoryLinks"
    ]
    resources = ["*"]
  }

  statement {
    sid     = "CodeConnectionsSync"
    actions = [
      "codeconnections:CreateSyncConfiguration",
      "codeconnections:UpdateSyncConfiguration",
      "codeconnections:DeleteSyncConfiguration",
      "codeconnections:GetSyncConfiguration",
      "codeconnections:ListSyncConfigurations"
    ]
    resources = ["*"]
  }

  statement {
    sid     = "EventBridgeForTriggers"
    actions = [
      "events:PutRule", "events:PutTargets",
      "events:DescribeRule", "events:DeleteRule"
    ]
    resources = ["*"]
  }

  statement {
    sid      = "PassRole"
    actions  = ["iam:PassRole"]
    resources = ["arn:aws:iam::${var.account_id}:role/service-role/codebuild-asn-demo-lab-service-role"]
  }
}

data "aws_iam_policy_document" "codebuild_eks_describe" {
  statement {
    actions   = ["eks:DescribeCluster"]
    resources = ["arn:aws:eks:${var.region}:${var.account_id}:cluster/${var.eks_cluster_name}"]
  }
}


resource "aws_iam_policy" "codepipeline" {
  name   = "emf-gfsn-codepipeline-policy"
  policy = data.aws_iam_policy_document.codepipeline_policy.json
}

resource "aws_iam_role_policy_attachment" "codepipeline_attach" {
  role       = aws_iam_role.codepipeline.name
  policy_arn = aws_iam_policy.codepipeline.arn
}

############################
# CodeBuild: usar role FIXA
############################
data "aws_iam_role" "codebuild_fixed" {
  name = "codebuild-asn-demo-lab-service-role"
}

# Anexos mínimos para build/deploy (se ainda não existirem)
resource "aws_iam_role_policy_attachment" "cb_ecr" {
  role       = data.aws_iam_role.codebuild_fixed.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

resource "aws_iam_role_policy_attachment" "cb_logs" {
  role       = data.aws_iam_role.codebuild_fixed.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
}

resource "aws_iam_role_policy_attachment" "cb_s3" {
  role       = data.aws_iam_role.codebuild_fixed.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

############################
# CodeBuild Projects
############################
resource "aws_codebuild_project" "build" {
  name         = "emf-gfsn-build"
  service_role = data.aws_iam_role.codebuild_fixed.arn

  artifacts { type = "CODEPIPELINE" }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/standard:7.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true

    environment_variable { 
        name = "ECR_REPO"           
        value = aws_ecr_repository.app.repository_url 
    }
    environment_variable { 
        name = "COMPONENT"          
        value = "todo-frontend" 
    }
    environment_variable { 
        name = "AWS_DEFAULT_REGION" 
        value = var.region 
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec-build.yml"
  }

  logs_config {
    cloudwatch_logs { group_name = "/codebuild/emf-gfsn-build" }
  }

  tags = { dupla = "emf-gfsn", periodo = "8" }
}

resource "aws_codebuild_project" "deploy" {
  name         = "emf-gfsn-deploy"
  service_role = data.aws_iam_role.codebuild_fixed.arn

  artifacts { type = "CODEPIPELINE" }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/standard:7.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = false

    environment_variable { 
        name = "EKS_CLUSTER_NAME"   
        value = var.eks_cluster_name 
    }
    environment_variable { 
        name = "AWS_DEFAULT_REGION" 
        value = var.region 
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec-deploy.yml"
  }

  logs_config {
    cloudwatch_logs { group_name = "/codebuild/emf-gfsn-deploy" }
  }

  tags = { dupla = "emf-gfsn", periodo = "8" }
}

############################
# CodePipeline
############################
resource "aws_codepipeline" "pipeline" {
  name     = "emf-gfsn-ci-cd"
  role_arn = aws_iam_role.codepipeline.arn
  pipeline_type = "V2"
  
  artifact_store {
    location = aws_s3_bucket.artifacts.bucket
    type     = "S3"
  }

  stage {
    name = "Source"
    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]
      configuration = {
        ConnectionArn        = var.codestar_connection_arn
        FullRepositoryId     = "${var.github_owner}/${var.repo_name}"
        BranchName           = var.branch
        OutputArtifactFormat = "CODE_ZIP"
      }
    }
  }

  stage {
    name = "Build"
    action {
      name             = "BuildImage"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]
      version          = "1"
      configuration = {
        ProjectName = aws_codebuild_project.build.name
      }
    }
  }

  stage {
    name = "Deploy"
    action {
      name            = "DeployToEKS"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      input_artifacts = ["build_output"]
      version         = "1"
      configuration = {
        ProjectName = aws_codebuild_project.deploy.name
      }
    }
  }

    # --- Git Trigger (CodeConnections/GitHub) ---
  trigger {
    provider_type = "CodeStarSourceConnection"
    git_configuration {
      source_action_name = "Source"
      push {
        branches { includes = [var.branch] }   # "main" por padrão
        # remova file_paths por ora
      }
    }
  }

  tags = { dupla = "emf-gfsn", periodo = "8" }
}

# IAM role for EventBridge to start the pipeline
data "aws_iam_policy_document" "events_assume" {
  statement { 
    actions = ["sts:AssumeRole"]
    principals { 
      type = "Service" 
      identifiers = ["events.amazonaws.com"] 
    }
  }
}
resource "aws_iam_role" "events_start_pipeline" {
  name               = "events-start-pipeline-role"
  assume_role_policy = data.aws_iam_policy_document.events_assume.json
}
data "aws_iam_policy_document" "events_start_policy" {
  statement {
    actions   = ["codepipeline:StartPipelineExecution"]
    resources = [aws_codepipeline.pipeline.arn]
  }
}
resource "aws_iam_policy" "events_start_policy" {
  name   = "events-start-pipeline-policy"
  policy = data.aws_iam_policy_document.events_start_policy.json
}
resource "aws_iam_role_policy_attachment" "events_start_attach" {
  role       = aws_iam_role.events_start_pipeline.name
  policy_arn = aws_iam_policy.events_start_policy.arn
}

# EventBridge rule: react to CodeConnections push events on your repo/branch
resource "aws_cloudwatch_event_rule" "codeconnections_push" {
  name        = "codeconnections-push-${var.repo_name}"
  description = "Trigger CodePipeline on Git push via CodeConnections"
  event_pattern = jsonencode({
    "source": ["aws.codeconnections"],
    "detail-type": ["CodeCommit Repository Trigger Event","Pull request merged","Branch or tag created","Branch or tag updated"],
    "detail": {
      "providerType": ["GitHub"],
      "repositoryName": [var.repo_name],
      "owner": [var.github_owner],
      "referenceType": ["branch"],
      "referenceName": [var.branch]
    }
  })
}

resource "aws_cloudwatch_event_target" "codeconnections_push_target" {
  rule      = aws_cloudwatch_event_rule.codeconnections_push.name
  arn       = aws_codepipeline.pipeline.arn
  role_arn  = aws_iam_role.events_start_pipeline.arn
}
