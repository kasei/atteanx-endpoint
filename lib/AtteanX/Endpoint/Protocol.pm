use v5.14;
use warnings;

=head1 NAME

AtteanX::Endpoint::Protocol - SPARQL 1.1 Protocol

=head1 VERSION

This document describes AtteanX::Endpoint::Protocol version 0.003

=head1 SYNOPSIS

  plackup -p 9091 scripts/endpoint.psgi

=head1 DESCRIPTION

The AtteanX::Endpoint::Protocol class implements the logic for the
SPARQL Protocol.

=head1 ATTRIBUTES

=over 4

=item C<< graph >>

The L<Attean::API::IRI> of the graph in the model that represents the default graph.

=back

=head1 METHODS

=over 4

=cut

package AtteanX::Endpoint::Protocol 0.003 {
	use Moo;
	use Attean;
	use Encode;
	use Attean::RDF qw(iri);
	use Types::Standard qw(ConsumerOf CodeRef HashRef ArrayRef Str Int);
	use HTML::HTML5::Writer qw(DOCTYPE_XHTML_RDFA);
	use namespace::clean;

	with 'MooX::Log::Any';

	has 'planner' => (
		is => 'ro',
		isa => ConsumerOf['Attean::API::QueryPlanner'],
		required => 1,
		default => sub {
			Attean::IDPQueryPlanner->new();
		}
	);
	has 'model' => (is => 'ro', isa => ConsumerOf['Attean::API::Model'], required => 1);
	has 'conf'	=> (is => 'ro', isa => HashRef, required => 1);
	has 'graph'	=> (is => 'ro', isa => ConsumerOf['Attean::API::IRI'], required => 1);

	sub run {
		my $self	= shift;
		my $req		= shift;
		my $env		= $req->env;
		my $response	= shift;

		my $config	= $self->{conf};
		my $model	= $self->{model};
		my $headers	= $req->headers;
		my $type	= $headers->header('Accept') || 'application/sparql-results+xml';
		if (my $t = $req->param('media-type')) {
			$type	= $t;
			$headers->header('Accept' => $type);
		}
	
		my $ae		= $req->headers->header('Accept-Encoding') || '';
	
		my $sparql;
		my $content;
		my $ct	= $req->header('Content-type');
		if ($req->method !~ /^(GET|POST)$/i) {
			my $method	= uc($req->method);
			$content	= "Unexpected method $method (expecting GET or POST)";
			$self->log_error( $req, $content );
			$response->header('Allow' => 'GET, POST');
			die AtteanX::Endpoint::ClientError->new(code => 405, message => 'Method not allowed', uri => 'http://id.kasei.us/rdf-endpoint/error/bad_http_method');
		} elsif (defined($ct) and $ct eq 'application/sparql-query') {
			$sparql	= $req->content;
		} elsif (defined($ct) and $ct eq 'application/sparql-update') {
			if ($config->{endpoint}{update} and $req->method eq 'POST') {
				$sparql	= $req->content;
			}
		} elsif ($req->param('query')) {
			my @sparql	= $req->param('query');
			if (scalar(@sparql) > 1) {
				$content	= "More than one query string submitted";
				$self->log_error( $req, $content );
				die AtteanX::Endpoint::ClientError->new(code => 400, message => 'Multiple query strings not allowed', uri => 'http://id.kasei.us/rdf-endpoint/error/multiple_queries');
			} else {
				$sparql = $sparql[0];
			}
		} elsif ($req->param('update')) {
			my @sparql	= $req->param('update');
			if (scalar(@sparql) > 1) {
				$content	= "More than one update string submitted";
				$self->log_error( $req, $content );
				die AtteanX::Endpoint::ClientError->new(code => 400, message => 'Multiple update strings not allowed', uri => 'http://id.kasei.us/rdf-endpoint/error/multiple_updates');
			}
		
			if ($config->{endpoint}{update} and $req->method eq 'POST') {
				$sparql = $sparql[0];
			} elsif ($req->method ne 'POST') {
				my $method	= $req->method;
				$content	= "Update operations must use POST";
				$self->log_error( $req, $content );
				$response->header('Allow' => 'POST');
				die AtteanX::Endpoint::ClientError->new(code => 405, message => "$method Not Allowed for Update Operation", uri => 'http://id.kasei.us/rdf-endpoint/error/bad_http_method_update');
			}
		}
	
		if ($sparql) {
			my %args;
			$args{ update }		= 1 if ($config->{endpoint}{update} and $req->method eq 'POST');
			$args{ load_data }	= 1 if ($config->{endpoint}{load_data});
		
			my $protocol_specifies_update_dataset	= 0;
			{
				my @default	= $req->param('default-graph-uri');
				my @named	= $req->param('named-graph-uri');
				if (scalar(@default) or scalar(@named)) {
					delete $args{ load_data };
					# TODO: handle custom-dataset
					$self->log->warn('custom query datasets not supported yet');
# 					$model	= Attean::MutableQuadModel->new( store => Attean->get_store('Memory')->new() );
# 					foreach my $url (@named) {
# 						RDF::Trine::Parser->parse_url_into_model( $url, $model, context => iri($url) );
# 					}
# 					foreach my $url (@default) {
# 						RDF::Trine::Parser->parse_url_into_model( $url, $model );
# 					}
				}
			}
		
			{
				my @default	= $req->param('using-graph-uri');
				my @named	= $req->param('using-named-graph-uri');
				if (scalar(@named) or scalar(@default)) {
					$protocol_specifies_update_dataset	= 1;
					# TODO: handle custom-dataset
					$self->log->warn('custom update datasets not supported yet');
# 					$model	= RDF::Trine::Model::Dataset->new( $model );
# 					$model->push_dataset( default => \@default, named => \@named );
				}
			}
		
# 			my $match	= $headers->header('if-none-match') || '';
# 			my $etag	= md5_base64( join('#', $self->run_tag, $model->etag, $type, $ae, $sparql) );
# 			if (length($match)) {
# 				if (defined($etag) and ($etag eq $match)) {
# 					$response->status(304);
# 					return $response;
# 				}
# 			}
		
			my $base	= $req->base;
			my $parser	= Attean->get_parser('SPARQL')->new(base => $base);
			$parser->update(1) if ($args{update});
			my ($algebra)	= eval { $args{update} ? $parser->parse_update($sparql, base => $base) : $parser->parse($sparql, base => $base) };
			if ($@ or not($algebra)) {
				my $error	= $@ || 'Internal error';
				$self->log_error( $req, $error );
				my $eclass	= ($error =~ /Syntax/) ? 'AtteanX::Endpoint::ClientError' : 'AtteanX::Endpoint::ServerError';
				if ($req->method ne 'POST' and $error =~ /read-only queries/sm) {
					$error	= 'Updates must use a HTTP POST request.';
					die $eclass->new(message => 'Updates must use a HTTP POST request', uri => 'http://id.kasei.us/rdf-endpoint/error/bad_http_method_update');
				} else {
					die $eclass->new(message => 'SPARQL query/update parse error', uri => 'http://id.kasei.us/rdf-endpoint/error/parse_error', details => { error => $error, sparql => $sparql });
				}
			} else {
				$self->log_query( $req, $sparql );
				# TODO: handle case where query specifies update dataset
# 				if ($protocol_specifies_update_dataset and $query->specifies_update_dataset) {
# 					my $method	= $req->method;
# 					$content	= "Update operations cannot specify a dataset in both the query and with protocol parameters";
# 					$self->log_error( $req, $content );
# 					die AtteanX::Endpoint::ClientError->new(code => 400, message => 'Multiple datasets specified for update', uri => 'http://id.kasei.us/rdf-endpoint/error/update_specifies_multiple_datasets');
# 				}
				if ($self->log->is_trace) {
					$self->log->trace("Algebra:\n" . $algebra->as_string);
				}
				my $graph	= $self->graph;
				my $default_graphs	= [$graph];
				my $planner	= $self->planner;
				if ($self->log->is_trace) {
					$self->log->debug('Planning with default graphs:');
					foreach my $g (@$default_graphs) {
						$self->log->trace($g->as_string);
					}
				}
				my $plan	= $planner->plan_for_algebra($algebra, $model, $default_graphs);
				if ($self->log->is_debug) {
					$self->log->debug("Plan:\n" . $plan->as_string);
				}
				eval {
					my $iter	= $plan->evaluate($model);
					$response->status(200);
					if ($headers->header('Accept') eq '*/*') {
						$headers->remove_header('Accept');
					}
					
					my $sclass	= Attean->negotiate_serializer(request_headers => $headers, role => 'Attean::API::ResultSerializer') // Attean->get_serializer('sparqlxml');
					my @args;
					if ($sclass eq 'AtteanX::Serializer::SPARQLHTML') {
						push(@args, head => <<"END");
							<style>
								table, th, td {
									border: 1px solid #000;
								}
								table {
									border-collapse: collapse;
								}
							</style>
END
					}
					$self->log->debug("Serializer class: $sclass");
					my $s		= $sclass->new(@args);
					$content	= $s->serialize_iter_to_bytes($iter);
					my $stype	= $s->canonical_media_type;
					$response->headers->content_type($stype);
				};
				if ($@) {
					my $error	= $@;
					$self->log->fatal($error);
					die AtteanX::Endpoint::ServerError->new(code => 500, message => 'SPARQL query/update execution error', uri => 'http://id.kasei.us/rdf-endpoint/error/execution_error', details => { error => $@, sparql => $sparql });
				}
			}
		} elsif ($req->method eq 'POST') {
			$content	= "POST without recognized query or update";
			$self->log_error( $req, $content );
			die AtteanX::Endpoint::ClientError->new(message => 'Missing SPARQL Query/Update String', uri => 'http://id.kasei.us/rdf-endpoint/error/missing_sparql_string');
		} else {
			my $stype		= 'text/html';
			my $dir			= $ENV{ATTEAN_ENDPOINT_SHAREDIR} || File::Spec->catdir((eval { dist_dir('AtteanX-Endpoint') } || 'share'), 'endpoint');
			my $template	= File::Spec->catfile($dir, 'index.html');
			my $parser		= XML::LibXML->new(validation => 0, suppress_errors => 1, no_network => 1, recover => 2);
			my $doc			= $parser->parse_file( $template );
# 			my $gen			= RDF::RDFa::Generator->new( style => 'HTML::Head');
# 			$gen->inject_document($doc, $sdmodel);
		
			my $writer	= HTML::HTML5::Writer->new( markup => 'xhtml', doctype => DOCTYPE_XHTML_RDFA );
			$content	= encode_utf8( $writer->document($doc) );
			$response->status(200);
			$response->headers->content_type('text/html');
		}
	
		return $content;
	}
	
=item C<< log_query ( $request, $sparql ) >>

Log the C<< $sparql >> query string after having been parsed from the
C<< $request >> but before evaluation.

=cut

	sub log_query {
		my $self	= shift;
		my $req		= shift;
		my $message	= shift;
		$self->log->info("SPARQL query:\n" . $message);
		$self->_log( $req, { level => 'info', message => $message } );
	}

=item C<< log_error ( $message ) >>

=cut

	sub log_error {
		my $self	= shift;
		my $req		= shift;
		my $message	= shift;
		$self->log->error($message);
		$self->_log( $req, { level => 'error', message => $message } );
	}

	sub _log {
		my $self	= shift;
		my $req		= shift;
		my $data	= shift;
		my $logger	= $req->logger || sub {};
	
		$logger->($data);
	}
}

1;

__END__

=back

=head1 BUGS

Please report any bugs or feature requests to through the GitHub web interface
at L<https://github.com/kasei/atteanx-endpoint/issues>.

=head1 AUTHOR

Gregory Todd Williams  C<< <gwilliams@cpan.org> >>

=head1 COPYRIGHT

Copyright (c) Gregory Todd Williams.
This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
