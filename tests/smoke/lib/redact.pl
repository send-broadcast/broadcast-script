#!/usr/bin/perl
# Masks secrets in what the smoke tests print and save (see smoke_redact in smoke_vm.sh).
#
#   redact.pl                    filter: stdin to stdout, as the output arrives
#   redact.pl --in-place FILE... rewrite saved files
#
# The secrets come from the file named by SMOKE_REDACT_SECRETS_FILE, one per line, so they never
# appear in a process list. The filter reads the file again when it changes, so a secret the
# harness learns later (the registry login on the VM) is masked from then on. Each secret is masked:
#   * whole, also when a terminal put line breaks, a wrap, escape codes or backspaces inside it
#   * in part: any 8 characters of it in a row (secrets of 12 characters or more), so a
#     cut-short echo shows nothing either
#   * across two writes: the filter keeps the last 512 characters back until more output comes,
#     or until the output is quiet; output that ends in the first characters of a secret is
#     held for up to 5 seconds for the rest
# Values of NAME=value lines whose name says secret (PASSWORD, SECRET, LICENSE, TOKEN, _KEY,
# _LOGIN), JSON credential fields, and --password arguments are masked too, registered or not.

use strict;
use warnings;
use IO::Select;

my $MASK = '<REDACTED>';
my $KEEP = 512;           # characters held back while the output flows
my $QUIET = 0.3;          # seconds without output before everything held is printed
my $PREFIX_HOLD = 5;      # seconds to wait for the rest of a secret

# What a terminal can put between two characters of a secret
my $GAP = '(?:\r|\n|\x08|\e\[[0-9;?]*[ -\/]*[@-~]|\e[()][0-9A-Za-z]|\e[=>78DEM])*';

my ($secret_re, $prefix_re, $secrets_stamp) = (undef, undef, '');

# (Re)builds the patterns when the secrets file changed
sub load_secrets {
    my $file = $ENV{SMOKE_REDACT_SECRETS_FILE} // '';
    my @st = $file ne '' ? stat($file) : ();
    my $stamp = @st ? "$st[7]:$st[9]:$st[1]" : '';
    return if $stamp eq $secrets_stamp;
    $secrets_stamp = $stamp;
    my $content = '';
    if ($stamp ne '' && open(my $fh, '<:raw', $file)) {
        local $/;
        $content = <$fh> // '';
        close $fh;
    }
    my (@whole, @prefixes);
    for my $secret (split /\n/, $content) {
        next if length($secret) < 4;
        my @c = map { quotemeta } split //, $secret;
        push @whole, join($GAP, @c);
        if (@c >= 12) {
            push @whole, join($GAP, @c[$_ .. $_ + 7]) for 0 .. @c - 8;
        }
        for (my $k = @c - 1; $k >= 3; $k--) {
            push @prefixes, join($GAP, @c[0 .. $k - 1]);
        }
    }
    $secret_re = @whole ? qr/(?=(@{[ join '|', @whole ]}))/ : undef;
    $prefix_re = @prefixes ? qr/(?:@{[ join '|', @prefixes ]})$GAP\z/ : undef;
}
load_secrets();

my @value_res = (
    qr/\b[A-Z0-9_]*(?:PASSWORD|SECRET|LICENSE|TOKEN|_KEY|_LOGIN)[A-Z0-9_]*=['"]?([^\s'"]+)/,
    qr/"(?:registry_login|registry_password|password|key|license|license_key|token)"\s*:\s*"([^"]+)"/i,
    qr/--password[= ]+(\S+)/,
);

# The masked character positions of $text, as a string of "\0" (keep) and "\1" (mask)
sub mask_of {
    my ($text, $forced) = @_;
    my $mask = "\0" x length($text);
    substr($mask, 0, $forced) = "\1" x $forced if $forced;
    my @spans;
    if ($secret_re) {
        while ($text =~ /$secret_re/g) {
            push @spans, [$-[1], $+[1]] if $+[1] > $-[1];
        }
    }
    for my $re (@value_res) {
        while ($text =~ /$re/g) {
            push @spans, [$-[1], $+[1]] if $+[1] > $-[1];
        }
    }
    substr($mask, $_->[0], $_->[1] - $_->[0]) = "\1" x ($_->[1] - $_->[0]) for @spans;
    return $mask;
}

# Prints the first $upto characters of $text with each masked run replaced by one $MASK.
# Returns how many characters after $upto belong to a masked run that started before it.
sub emit {
    my ($text, $upto, $forced) = @_;
    my $mask = mask_of($text, $forced);
    my $out = '';
    my $i = 0;
    while ($i < $upto) {
        my $j = $i;
        my $flag = substr($mask, $i, 1);
        $j++ while $j < $upto && substr($mask, $j, 1) eq $flag;
        if ($flag eq "\1") {
            # The rest of a run already shown as $MASK in the previous piece
            $out .= $MASK unless $i == 0 && $forced;
        } else {
            $out .= substr($text, $i, $j - $i);
        }
        $i = $j;
    }
    print $out;
    my $carry = 0;
    if ($upto > 0 && substr($mask, $upto - 1, 1) eq "\1") {
        $carry++ while $upto + $carry < length($text) && substr($mask, $upto + $carry, 1) eq "\1";
    }
    return $carry;
}

if (@ARGV && $ARGV[0] eq '--in-place') {
    shift @ARGV;
    for my $file (@ARGV) {
        next unless -f $file;
        open(my $in, '<:raw', $file) or die "redact: cannot read $file: $!\n";
        my $text = do { local $/; <$in> };
        close $in;
        $text = '' unless defined $text;
        open(my $out, '>:raw', $file) or die "redact: cannot write $file: $!\n";
        my $old = select($out);
        emit($text, length($text), 0);
        select($old);
        close $out or die "redact: cannot write $file: $!\n";
    }
    exit 0;
}

binmode STDIN;
binmode STDOUT;
$| = 1;
my $select = IO::Select->new(\*STDIN);
my ($buf, $forced, $held_since) = ('', 0, undef);
while (1) {
    my @ready = $select->can_read(length($buf) ? $QUIET : undef);
    if (!@ready) {
        # Quiet: print what is held, except the start of a secret whose rest may still come
        if ($prefix_re && $buf =~ $prefix_re && (!defined $held_since || time - $held_since < $PREFIX_HOLD)) {
            $held_since //= time;
            my $start = $-[0];
            $forced = emit($buf, $start, $forced);
            $buf = substr($buf, $start);
            next;
        }
        emit($buf, length($buf), $forced);
        ($buf, $forced, $held_since) = ('', 0, undef);
        next;
    }
    my $n = sysread(STDIN, my $chunk, 65536);
    if (!defined $n) {
        next if $!{EINTR};
        last;
    }
    last if $n == 0;
    load_secrets();
    $buf .= $chunk;
    $held_since = undef;
    if (length($buf) > $KEEP) {
        my $upto = length($buf) - $KEEP;
        $forced = emit($buf, $upto, $forced);
        $buf = substr($buf, $upto);
    }
}
emit($buf, length($buf), $forced);
