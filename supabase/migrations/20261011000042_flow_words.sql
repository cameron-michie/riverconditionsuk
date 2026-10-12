-- Flow readings are phrases about normal, not a good/bad scale.
update core.signal_def set words = '{"much lower than normal","lower than normal","about normal","higher than normal","much higher than normal"}' where code = 'flow';
