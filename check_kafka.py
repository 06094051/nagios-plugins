#!/usr/bin/env python
#  vim:ts=4:sts=4:sw=4:et
#
#  Author: Hari Sekhon
#  Date: 2016-02-15 23:58:38 +0000 (Mon, 15 Feb 2016)
#  port of Perl version Date: 2015-01-04 20:49:58 +0000 (Sun, 04 Jan 2015)
#
#  https://github.com/harisekhon/nagios-plugins
#
#  License: see accompanying Hari Sekhon LICENSE file
#
#  If you're using my code you're welcome to connect with me on LinkedIn
#  and optionally send me feedback to help steer this or other code I publish
#
#  https://www.linkedin.com/in/harisekhon
#

"""

Nagios Plugin to check a Kafka cluster is working by using the APIs to validate passing a unique message
through the brokers

This is a port of my Perl check_kafka.pl since one of the underlying Perl library's dependencies
developed an autoload bug which needs manual fixing before that Perl version can be run (documented
at the landing page at https://github.com/harisekhon/nagios-plugins).

The Perl version does have better info for --list-partitions however, including Replicas,
ISRs and Leader info per partition.

Thresholds apply to max produce / consume message timings which are also output as perfdata for graphing

Tested on Kafka 0.8.1, 0.8.2.2, 0.9.0.1
"""

from __future__ import absolute_import
from __future__ import division
from __future__ import print_function
#from __future__ import unicode_literals

import os
import sys
import traceback
try:
    from kafka import KafkaConsumer, KafkaProducer
    from kafka.common import KafkaError, TopicPartition
except ImportError:
    print(traceback.format_exc(), end='')
    sys.exit(4)
libdir = os.path.abspath(os.path.join(os.path.dirname(__file__), 'pylib'))
sys.path.append(libdir)
try:
    # pylint: disable=wrong-import-position
    from harisekhon.utils import log, log_option, ERRORS, CriticalError, UnknownError
    from harisekhon.utils import validate_int, get_topfile, random_alnum, validate_chars, isSet
    from harisekhon import PubSubNagiosPlugin
except ImportError as _:
    print(traceback.format_exc(), end='')
    sys.exit(4)

__author__ = 'Hari Sekhon'
__version__ = '0.3.4'


class CheckKafka(PubSubNagiosPlugin):

    def __init__(self):
        # Python 2.x
        super(CheckKafka, self).__init__()
        # Python 3.x
        # super().__init__()
        self.name = 'Kafka'
        self.default_port = 9092
        self.producer = None
        self.consumer = None
        self.topic = None
        self.client_id = 'Hari Sekhon ' + os.path.basename(get_topfile()) + ' ' + __version__
        self.group_id = self.client_id + ' ' + str(os.getpid()) + ' ' + random_alnum(10)
        self.acks = '1'
        self.retries = 0
        self.partition = None
        self.topic_partition = None
        self.brokers = None
        self.timeout_ms = None
        self.start_offset = None

    def add_options(self):
        # super(CheckKafka, self).add_options()
        # TODO: (host_envs, default_host) = getenvs2('HOST', default_host, name)
        # TODO: env support for Kafka brokers
        self.add_opt('-H', '--host', \
                     '-B', '--brokers', \
                     dest='brokers', metavar='broker_list', default='localhost:9092',
                     help='Kafka Broker seed list in form host[:port],host2[:port2]... (default: localhost:9092)')
        self.add_opt('-T', '--topic', help='Kafka Topic')
        self.add_opt('-p', '--partition', type=int, help='Kafka Partition (default: 0)', default=0)
        self.add_opt('-a', '--acks', default=1, choices=[1, 'all'],
                     help='Acks to require from Kafka. Valid options are \'1\' for Kafka ' +
                     'partition leader, or \'all\' for all In-Sync Replicas (may block causing ' +
                     'timeout if replicas aren\'t available, default: 1)')
        self.add_opt('-s', '--sleep', metavar='secs',
                     help='Sleep in seconds between producing and consuming from given topic (default: 0.5)')
        self.add_opt('--list-topics', action='store_true', help='List Kafka topics from broker(s) and exit')
        self.add_opt('--list-partitions', action='store_true',
                     help='List Kafka topic paritions from broker(s) and exit')
        self.add_thresholds(default_warning=1, default_critical=2)

    def run(self):
        try:
            super(CheckKafka, self).run()
        #except KafkaError as _:
            #raise CriticalError(_)
        except KafkaError:
            raise CriticalError(self.exception_msg())

    @staticmethod
    def exception_msg():
        return traceback.format_exc().split('\n')[-2]

    def get_topics(self):
        self.consumer = KafkaConsumer(
            bootstrap_servers=self.brokers,
            client_id=self.client_id,
            request_timeout_ms=self.timeout_ms
            )
        return self.consumer.topics()

    def print_topics(self):
        print('Kafka Topics:\n')
        for topic in self.get_topics():
            print(topic)

    def get_topic_partitions(self, topic):
        self.consumer = KafkaConsumer(
            topic,
            bootstrap_servers=self.brokers,
            client_id=self.client_id,
            request_timeout_ms=self.timeout_ms
            )
        if topic not in self.get_topics():
            raise CriticalError("topic '{0}' does not exist on Kafka broker".format(topic))
        partitions = self.consumer.partitions_for_topic(topic)
        assert isSet(partitions)
        return partitions

    def print_topic_partitions(self, topic):
        print('Kafka topic \'{0}\' partitions:\n'.format(topic))
        #for partition in self.get_topic_partitions(topic):
        #    print(partition)
        print(list(self.get_topic_partitions(topic)))
        print()

    def process_args(self):
        self.brokers = self.get_opt('brokers')
        # TODO: add broker list validation back in
        # validate_hostport(self.brokers)
        log_option('brokers', self.brokers)
        self.timeout_ms = max((self.timeout * 1000 - 1000) / 2, 1000)

        try:
            list_topics = self.get_opt('list_topics')
            list_partitions = self.get_opt('list_partitions')
            if list_topics:
                self.print_topics()
                sys.exit(ERRORS['UNKNOWN'])
            self.topic = self.get_opt('topic')
        except KafkaError:
            raise CriticalError(self.exception_msg())

        if self.topic:
            validate_chars(self.topic, 'topic', 'A-Za-z-')
        elif list_topics or list_partitions:
            pass
        else:
            self.usage('--topic not specified')

        try:
            if list_partitions:
                if self.topic:
                    self.print_topic_partitions(self.topic)
                else:
                    for topic in self.get_topics():
                        self.print_topic_partitions(topic)
                sys.exit(ERRORS['UNKNOWN'])
        except KafkaError:
            raise CriticalError(self.exception_msg())

        self.partition = self.get_opt('partition')
        # technically optional, will hash to a random partition, but need to know which partition to get offset
        # if self.partition is not None:
        validate_int(self.partition, "partition", 0, 10000)
        self.topic_partition = TopicPartition(self.topic, self.partition)
        self.acks = self.get_opt('acks')
        log_option('acks', self.acks)
        self.validate_thresholds()

    def subscribe(self):
        self.consumer = KafkaConsumer(
            #self.topic,
            bootstrap_servers=self.brokers,
            # client_id=self.client_id,
            # group_id=self.group_id,
            request_timeout_ms=self.timeout_ms
            )
            #key_serializer
            #value_serializer
        log.debug('partition assignments: {0}'.format(self.consumer.assignment()))

        # log.debug('subscribing to topic \'{0}\' parition \'{1}\''.format(self.topic, self.partition))
        # self.consumer.subscribe(TopicPartition(self.topic, self.partition))
        # log.debug('partition assignments: {0}'.format(self.consumer.assignment()))

        log.debug('assigning partition {0} to consumer'.format(self.partition))
        # self.consumer.assign([self.partition])
        self.consumer.assign([self.topic_partition])
        log.debug('partition assignments: {0}'.format(self.consumer.assignment()))

        log.debug('getting current offset')
        # see also highwater, committed, seek_to_end
        self.start_offset = self.consumer.position(self.topic_partition)
        if self.start_offset is None:
            # don't do this, I've seen scenario where None is returned and all messages are read again, better to fail
            # log.warn('consumer position returned None, resetting to zero')
            # self.start_offset = 0
            raise UnknownError('Kafka Consumer reported current starting offset = {0}'.format(self.start_offset))
        log.debug('recorded starting offset \'{0}\''.format(self.start_offset))
        # self.consumer.pause()

    def publish(self):
        log.debug('creating producer')
        self.producer = KafkaProducer(
            bootstrap_servers=self.brokers,
            client_id=self.client_id,
            acks=self.acks,
            batch_size=0,
            max_block_ms=self.timeout_ms,
            request_timeout_ms=self.timeout_ms
            )
            #key_serializer
            #value_serializer
        log.debug('producer.send()')
        self.producer.send(
            self.topic,
            key=self.key,
            partition=self.partition,
            value=self.publish_message
            )
        log.debug('producer.flush()')
        self.producer.flush()

    def consume(self):
        self.consumer.assign([self.topic_partition])
        log.debug('consumer.seek({0})'.format(self.start_offset))
        self.consumer.seek(self.topic_partition, self.start_offset)
        # self.consumer.resume()
        log.debug('consumer.poll(timeout_ms={0})'.format(self.timeout_ms))
        obj = self.consumer.poll(timeout_ms=self.timeout_ms)
        log.debug('msg object returned: %s', obj)
        msg = None
        try:
            for consumer_record in obj[self.topic_partition]:
                if consumer_record.key == self.key:
                    msg = consumer_record.value
                    break
        except KeyError:
            raise UnknownError('TopicPartition key was not found in response')
        if msg is None:
            raise UnknownError("failed to find matching consumer record with key '{0}'".format(self.key))
        return msg


if __name__ == '__main__':
    CheckKafka().main()
