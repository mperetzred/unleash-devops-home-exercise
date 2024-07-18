variable "aws_region" {
  description = "The AWS region to deploy to"
  type        = string
  default     = "us-east-2"
}

variable "bucket_name" {
  description = "The name of the S3 bucket"
  type        = string
}

variable "image_tag" {
  description = "The tag of the image"
  type        = string
}

variable "port" {
  description = "The port for the application"
  type        = string
  default     = "3000"
}
