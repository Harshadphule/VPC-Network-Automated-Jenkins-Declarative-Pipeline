# S3 bucket for storing logs or other resources (optional)
resource "aws_s3_bucket" "example" {
  bucket = var.bucket_name
  tags = {
    Name = "Terraform-Bucket"
  }
}
