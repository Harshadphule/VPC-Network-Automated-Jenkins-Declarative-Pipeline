terraform {
  backend "s3" {
    bucket = "terraform-vpc-state-bucket-freestyle-1"
    key    = "remotedemo.tfstate"
    region = "ap-south-1"
  }
}
