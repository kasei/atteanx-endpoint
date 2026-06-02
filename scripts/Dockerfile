FROM perl:5.42.2

WORKDIR /usr/src/attean

RUN apt-get update; \
    apt-get install -y liblmdb-dev \
    ; \
    apt-get dist-clean

RUN cpanm --installdeps Attean \
	&& cpanm --installdeps AtteanX::Store::LMDB \
	&& cpanm --installdeps AtteanX::Endpoint
RUN cpanm AtteanX::Parser::JSONLD
RUN cpanm Attean \
	&& cpanm AtteanX::Store::LMDB \
	&& cpanm AtteanX::Endpoint
RUN cpanm Config::JFDI
RUN cpanm Reply::App
RUN cpanm Plack::Middleware::LogErrors

RUN cpanm Module::Install \
	&& cpanm Module::Install::DOAPChangeSets \
	&& cpanm Module::Install::AuthorTests \
	&& cpanm Module::Install::Scripts

COPY . .
RUN perl Makefile.PL && make && make test && make install

# Create and initialize an empty LMDB file to back the endpoint.
# The /opt/endpoint/data path can be mounted to instead use an
# LMDB file that exists outside of the container.
RUN mkdir -p /opt/endpoint/data && attean_lmdb_create /opt/endpoint/data/data.lmdb
RUN mkdir -p /opt/endpoint/html
COPY share/endpoint /opt/endpoint/html

ENV PERLRDF_STORE=LMDB=/opt/endpoint/data/data.lmdb
ENV ATTEAN_ENDPOINT_SHAREDIR=/opt/endpoint/html

VOLUME ["/opt/endpoint/data"]
VOLUME ["/opt/endpoint/html/templates"]

EXPOSE 9090

CMD ["/usr/local/bin/plackup", "/usr/local/bin/endpoint.psgi", "--port", "9090"]
