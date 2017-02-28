require('onmt.init')

local cmd = onmt.utils.ExtendedCmdLine.new('train.lua')

-- First argument define the model type: seq2seq/lm - default is seq2seq.
local modelType = cmd.getArgument(arg, '-model_type') or 'seq2seq'

local modelClass = onmt.ModelSelector(modelType)

-- Options declaration.
local options = {
  {'-data',       '', [[Path to the training *-train.t7 file from preprocess.lua]],
                      {valid=onmt.utils.ExtendedCmdLine.nonEmpty}},
  {'-save_model', '', [[Model filename (the model will be saved as
                            <save_model>_epochN_PPL.t7 where PPL is the validation perplexity]],
                      {valid=onmt.utils.ExtendedCmdLine.nonEmpty}}
}

cmd:setCmdLineOptions(options, 'Data')

onmt.Model.declareOpts(cmd)
modelClass.declareOpts(cmd)
onmt.train.Optim.declareOpts(cmd)
onmt.train.Trainer.declareOpts(cmd)
onmt.train.Checkpoint.declareOpts(cmd)

cmd:text('')
cmd:text('**Other options**')
cmd:text('')

onmt.utils.Cuda.declareOpts(cmd)
onmt.utils.Memory.declareOpts(cmd)
onmt.utils.Logger.declareOpts(cmd)
onmt.utils.Profiler.declareOpts(cmd)

cmd:option('-seed', 3435, [[Seed for random initialization.]], {valid=onmt.utils.ExtendedCmdLine.isUInt()})

local opt = cmd:parse(arg)

local function main()

  torch.manualSeed(opt.seed)

  _G.logger = onmt.utils.Logger.new(opt.log_file, opt.disable_logs, opt.log_level)
  _G.profiler = onmt.utils.Profiler.new(false)

  onmt.utils.Cuda.init(opt)
  onmt.utils.Parallel.init(opt)

  local checkpoint
  checkpoint, opt = onmt.train.Checkpoint.loadFromCheckpoint(opt)

  _G.logger:info('Training '..modelClass.modelName()..' model')

  -- Create the data loader class.
  _G.logger:info('Loading data from \'' .. opt.data .. '\'...')

  local dataset = torch.load(opt.data, 'binary', false)

  -- Keep backward compatibility.
  dataset.dataType = dataset.dataType or 'bitext'

  -- Check if data type matches the model.
  if not modelClass.dataType(dataset.dataType) then
    _G.logger:error('Data type: \'' .. dataset.dataType .. '\' does not match model type: \'' .. modelClass.modelName() .. '\'')
    os.exit(0)
  end

  -- record datatype in the options, and preprocessing options if present
  opt.data_type = dataset.dataType
  opt.preprocess = dataset.opt

  local trainData = onmt.data.Dataset.new(dataset.train.src, dataset.train.tgt)
  local validData = onmt.data.Dataset.new(dataset.valid.src, dataset.valid.tgt)

  trainData:setBatchSize(opt.max_batch_size, opt.same_size_batch)
  validData:setBatchSize(opt.max_batch_size, opt.same_size_batch)

  if dataset.dataType ~= 'monotext' then
    local srcVocSize
    local srcFeatSize = '-'
    if dataset.dicts.src then
      srcVocSize = dataset.dicts.src.words:size()
      srcFeatSize = #dataset.dicts.src.features
    else
      srcVocSize = '*'..dataset.dicts.srcInputSize
    end
    local tgtVocSize
    local tgtFeatSize = '-'
    if dataset.dicts.tgt then
      tgtVocSize = dataset.dicts.tgt.words:size()
      tgtFeatSize = #dataset.dicts.tgt.features
    else
      tgtVocSize = '*'..dataset.dicts.tgtInputSize
    end
    _G.logger:info(' * vocabulary size: source = %s; target = %s',
                   srcVocSize, tgtVocSize)
    _G.logger:info(' * additional features: source = %s; target = %s',
                   srcFeatSize, tgtFeatSize)
  else
    _G.logger:info(' * vocabulary size: %d', dataset.dicts.src.words:size())
    _G.logger:info(' * additional features: %d', #dataset.dicts.src.features)
  end
  _G.logger:info(' * maximum sequence length: source = %d; target = %d',
                 trainData.maxSourceLength, trainData.maxTargetLength)
  _G.logger:info(' * number of training sentences: %d', #trainData.src)
  _G.logger:info(' * maximum batch size: %d', opt.max_batch_size)

  _G.logger:info('Building model...')

  local model

  -- Build or load model from checkpoint and copy to GPUs.
  onmt.utils.Parallel.launch(function(idx)
    local _modelClass = onmt.ModelSelector(modelType)
    if checkpoint.models then
      _G.model = _modelClass.load(opt, checkpoint.models, dataset.dicts, idx > 1)
    else
      local verbose = idx == 1
      _G.model = _modelClass.new(opt, dataset.dicts, verbose)
    end
    onmt.utils.Cuda.convert(_G.model)
    return idx, _G.model
  end, function(idx, themodel)
    if idx == 1 then
      model = themodel
    end
  end)

  -- Define optimization method.
  local optimStates = (checkpoint.info and checkpoint.info.optimStates) or nil
  local optim = onmt.train.Optim.new(opt, optimStates)

  -- Initialize trainer.
  local trainer = onmt.train.Trainer.new(opt)

  -- Launch training.
  trainer:train(model, optim, trainData, validData, dataset, checkpoint.info)

  _G.logger:shutDown()
end

main()
