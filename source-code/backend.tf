terraform {
  backend "s3" {
    bucket = "terraform-vpc-state-bucket-declerative-1"
    key    = "remotedemo.tfstate"
    region = "ap-south-1"
  }
}
