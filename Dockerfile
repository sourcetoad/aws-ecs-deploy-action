FROM amazon/aws-cli:2.27.11

COPY deploy.sh /deploy.sh

# Get tools needed for packaging
RUN yum install -y jq && \
    yum clean all && \
    rm -rf /var/cache/yum
