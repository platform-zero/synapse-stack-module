FROM matrixdotorg/synapse:v1.141.0

USER root

RUN pip install --no-cache-dir \
    authlib==1.3.0

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        libsasl2-2 \
        gettext-base && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

ENTRYPOINT ["/entrypoint.sh"]
CMD []

USER 991:991
