# EC2

Elastic Compute Cloud is a virtual machine you rent by the second. You get the
operating system and everything above it; AWS runs the hardware, the hypervisor
and the network.

## Launching one

An instance needs four things:

| Input | What it decides |
|---|---|
| AMI | the disk image, so the OS and any preinstalled software |
| Instance type | CPU, memory, network, and the price |
| Key pair | the SSH public key baked in at first boot |
| Security group | which traffic reaches it |

## AMI

An Amazon Machine Image is a snapshot of a root volume plus metadata. AMIs are
**per region**, so the same logical image has a different ID in each one. That
is why hardcoding an AMI ID makes a Terraform configuration unusable elsewhere,
and why the `aws_ami` data source exists.

## Instance types

The name encodes the family, generation and size: `t3.micro` is the `t`
burstable family, generation 3, micro size. `m` is general purpose, `c` is
compute optimised, `r` is memory optimised.

The `t` family is worth knowing about: it runs at a baseline and spends CPU
credits to burst above it. Run out of credits and the instance is throttled
hard, which looks like a mysterious slowdown rather than an error.

## Storage

**EBS** is a network attached volume that persists independently of the
instance. Stop and start the instance and the data is still there.

**Instance store** is physically attached to the host. It is faster and it is
gone the moment the instance stops, which is correct for scratch and wrong for
anything else.

## Addressing

| | Survives a stop | Reachable from outside |
|---|---|---|
| Private IP | yes | no |
| Public IP | **no**, reassigned on start | yes |
| Elastic IP | yes | yes |

The public IP changing across a stop and start surprises people. An Elastic IP
is the fix when the address must be stable.

## Lifecycle

`pending` to `running`, then `stopping` and `stopped`, or `terminated` which is
final. A stopped instance costs nothing for compute but still costs for its EBS
volume. A terminated instance usually takes its root volume with it.
