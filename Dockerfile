FROM amazon/aws-cli:2.36.49

COPY deploy.sh /deploy.sh

# Get tools needed for packaging
RUN yum install -y jq diffutils && \
    yum clean all && \
    rm -rf /var/cache/yum
