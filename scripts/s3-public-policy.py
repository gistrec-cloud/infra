#!/usr/bin/env python3
"""Публичное чтение бакетов Gcore через bucket policy — аналог anonymous_access_flags
в Яндексе: объекты читаются без ACL на каждом, приложениям ничего не менять.
Запуск на finland-01 (boto3 есть в venv ctb), ключи из /root/s3-mirror.env:
  . /root/s3-mirror.env; export GC_ACCESS_KEY GC_SECRET_KEY
  /home/gistrec/ClearTranscriptBot/venv/bin/python -I s3-public-policy.py <bucket>...
"""
import json
import os
import sys
import urllib.request

import boto3

ENDPOINT = "https://s-ed1.cloud.gcore.lu"
s3 = boto3.client("s3", endpoint_url=ENDPOINT, region_name="s-ed1",
                  aws_access_key_id=os.environ["GC_ACCESS_KEY"],
                  aws_secret_access_key=os.environ["GC_SECRET_KEY"])

for bucket in sys.argv[1:]:
    policy = {"Version": "2012-10-17", "Statement": [{
        "Sid": "PublicRead", "Effect": "Allow", "Principal": "*",
        "Action": ["s3:GetObject"], "Resource": [f"arn:aws:s3:::{bucket}/*"]}]}
    s3.put_bucket_policy(Bucket=bucket, Policy=json.dumps(policy))
    # проверка: первый объект читается анонимно
    objs = s3.list_objects_v2(Bucket=bucket, MaxKeys=1).get("Contents", [])
    status = "empty"
    if objs:
        try:
            status = urllib.request.urlopen(f"{ENDPOINT}/{bucket}/{objs[0]['Key']}", timeout=15).status
        except Exception as e:  # noqa: BLE001
            status = getattr(e, "code", repr(e))
    print(f"{bucket}: policy set, anon GET {status}")
