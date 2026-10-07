# IAM

Identity and Access Management decides who may call which AWS API against which
resource. Every request to AWS is signed and evaluated against IAM before
anything happens.

## The four objects

| Object | What it is | Has credentials |
|---|---|---|
| User | a person or a long lived service identity | yes, password or access key |
| Group | a bag of users, used only to attach policies | no |
| Role | a set of permissions something assumes temporarily | no, issues short lived ones |
| Policy | a JSON document listing allowed or denied actions | n/a |

A policy is attached to a user, group or role. It is not an identity itself.

## Roles are the one to understand

A user has a permanent access key. A role has none: a principal **assumes** it
and receives temporary credentials that expire, usually in an hour.

That is why an EC2 instance should carry an instance profile rather than an
access key in a file. Nothing is stored on disk to leak, and the credentials
rotate themselves.

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:GetObject"],
    "Resource": "arn:aws:s3:::my-bucket/*"
  }]
}
```

`Resource` ending `/*` grants access to objects. Granting access to the bucket
itself, for `s3:ListBucket`, needs the ARN without `/*`. Mixing those two up is
the usual reason a policy looks right and does not work.

## How a request is evaluated

1. An explicit **Deny** anywhere wins, always.
2. Otherwise an explicit **Allow** permits it.
3. Otherwise it is denied, because the default is deny.

Service Control Policies sit above all of this at the organization level. They
never grant anything, they only cap what the account may do. I hit this
directly: the AWS account used for this coursework sits on the free plan, whose
SCP denies EC2 and S3 outright, and no IAM policy inside the account can
override it. That is recorded in
[`../../README.md`](../../README.md#11-the-aws-configuration).

## Least privilege in practice

Start from nothing and add what breaks. The opposite order, starting from
`AdministratorAccess` and trimming, never gets trimmed.

- Prefer roles over users, and instance profiles over keys on disk.
- Scope `Resource` to specific ARNs rather than `*`.
- Put MFA on anything human.
- Use the root user to create the first admin and then never again.

## Where it shows up

Cross account access, CI pipelines assuming a deploy role via OIDC instead of
holding a long lived key, and service to service calls inside AWS.
