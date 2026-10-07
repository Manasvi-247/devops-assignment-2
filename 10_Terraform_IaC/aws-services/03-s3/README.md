# S3

Simple Storage Service holds objects in buckets. It is not a filesystem: there
are no real directories, and a key like `logs/2026/app.log` is one flat string
that the console displays as folders.

## Buckets and objects

A bucket name is **globally unique across all of AWS**, which is why examples
end up with account numbers in them. The bucket in
[`../../aws-s3-demo`](../../aws-s3-demo) is named
`devops-course-24bcs10406-demo` for that reason.

An object is the bytes plus its key, metadata and a version ID. Maximum object
size is 5 TB, and anything over 5 GB has to use multipart upload.

## Storage classes

| Class | For | Retrieval |
|---|---|---|
| Standard | frequently read | immediate |
| Standard-IA | read occasionally | immediate, with a per GB fee |
| One Zone-IA | re-creatable data | immediate, one AZ only |
| Glacier Instant | archive, still read sometimes | immediate |
| Glacier Deep Archive | compliance retention | hours |

IA classes charge a minimum of 30 days per object, so moving short lived
objects there costs more than leaving them in Standard.

## Versioning

Off by default. Once enabled it can be suspended but **never turned off**, and
every overwrite keeps the old version, which keeps billing for it. A delete
writes a delete marker rather than removing anything.

The demo enables it explicitly:

```hcl
resource "aws_s3_bucket_versioning" "demo" {
  bucket = aws_s3_bucket.demo.id
  versioning_configuration {
    status = "Enabled"
  }
}
```

## Lifecycle policies

Rules that transition or expire objects by age or prefix. The usual shape is
Standard for 30 days, then IA, then Glacier at 90, then expire at some
retention limit. Pair this with versioning, or old versions accumulate forever.

## Encryption

Server side encryption is applied on write. `SSE-S3` uses keys AWS manages,
`SSE-KMS` uses a key you control and can audit, `SSE-C` uses a key you supply
per request. The demo sets `AES256`, which is `SSE-S3`.

## Access control

Public access is blocked by default at the account level, and the demo sets the
block explicitly rather than relying on that default:

```hcl
block_public_acls       = true
block_public_policy     = true
ignore_public_acls      = true
restrict_public_buckets = true
```

Prefer a **bucket policy** over ACLs. ACLs are the older mechanism and AWS now
disables them on new buckets. Public read on a bucket is the classic breach, so
the right pattern for serving files publicly is CloudFront with an Origin
Access Control, leaving the bucket itself private.

## Where it shows up

Static sites behind CloudFront, build artifacts, backups, data lake storage,
and Terraform remote state, which is the use in this coursework.
