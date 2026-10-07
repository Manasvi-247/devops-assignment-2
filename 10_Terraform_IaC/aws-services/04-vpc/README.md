# VPC

A Virtual Private Cloud is a private network inside a region. Everything with
an IP lives in one.

The configuration described here is built for real in
[`../../../11_Cloud_Terraform`](../../../11_Cloud_Terraform), which applies it
and then reads every resource back with the AWS CLI.

## CIDR

The VPC gets one block, fixed at creation and not changeable. `10.20.0.0/16`
gives 65,536 addresses.

Subnets carve it up. `10.20.1.0/24` is 256 of them, but **AWS reserves 5 per
subnet**: network, VPC router, DNS, future use, and broadcast. So a /24 gives
251 usable, not 254.

Pick a range that will not collide with anything you might later peer with. The
default `172.31.0.0/16` collides with other defaults constantly.

## Subnets

A subnet lives in exactly **one availability zone**. Spreading across two zones
is the cheapest availability you can buy, which is why the project uses
`ap-south-1a` and `ap-south-1b`.

Nothing on a subnet marks it public or private. There is no such flag.

## Route tables, and what public actually means

A subnet is public **only** because its route table sends `0.0.0.0/0` to an
internet gateway:

```text
DestinationCidrBlock   GatewayId      Origin
10.20.0.0/16           local          CreateRouteTable
0.0.0.0/0              igw-ac370ba0   CreateRoute
```

The `local` route is created automatically and cannot be removed. The second is
the one you add, and it is the entire difference.

A route table that is not **associated** with a subnet does nothing, which is
the step people forget.

## Internet Gateway and NAT Gateway

| | Direction | Cost |
|---|---|---|
| Internet Gateway | both ways, for instances with a public IP | free |
| NAT Gateway | outbound only, for private subnets | about $32 a month plus data |

The NAT Gateway is usually the most expensive thing in a small VPC. A private
subnet with no outbound need does not require one.

## Security Groups and Network ACLs

| | Security Group | Network ACL |
|---|---|---|
| Attached to | an interface | a subnet |
| State | stateful | stateless |
| Rules | allow only | allow and deny |
| Return traffic | automatic | needs its own rule |

Stateful matters: allowing inbound 80 on a security group automatically permits
the response out. On a NACL you would have to allow the ephemeral port range
back.

Security groups can reference **another security group** as a source, which is
how a database tier allows 5432 from the web tier without naming any IP range.

`0.0.0.0/0` on port 80 is reasonable. On port 22 it is the single most common
real world misconfiguration.
