FROM amazon/aws-cli:2.9.22

COPY deploy.sh /deploy.sh

# Get tools needed for packaging
RUN yum update -y && \
    yum install -y jq && \
    yum clean all && \
    rm -rf /var/cache/yum
